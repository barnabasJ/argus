defmodule Argus.Driver do
  @moduledoc """
  The run every frontend makes over a project: its beams set as the
  graph's program, the environment set, the analyses demanded, the
  graph kept for the next run (`Argus.Graph`).

  One session lives for the duration of a run (`Roux.Session`), opened
  from the project's manifest (`compile.argus` in its state directory)
  and committed back to it only when the run changed something: a warm
  run with nothing moved validates the graph and writes nothing. What a
  run computes lives in the blob store the manifest names by digest
  (`Argus.Graph.store/0`), shared by every project and worktree on the
  machine.

  The beams are synced with `Roux.Sources`: a beam whose size and
  modification time match the last run's is not read, unless it was
  written within the last two seconds (a fast edit-compile-edit can
  rewrite one in the same second with the same size); anything else is
  read and hashed without the chunks extraction never reads, so a beam
  Elixir rewrote only to refresh its type checker table moves nothing.
  The modules the `ignore` patterns keep out of analysis are synced too:
  never analyzed, but their specs are read by their callers'
  extraction, which depends on their beams.

  Without the engines (no Rust to build them: `Argus.FlowLog.available?/0`)
  nothing is solved: no analysis is demanded, and the result says so
  (`:engine_unavailable`). What failed is never kept — a
  solve that failed, a module extraction lost to a timeout, and every
  query that read one (`transient:`, `Roux.Query`) — so the next run
  tries it again.
  """

  alias Argus.Driver.Result
  alias Argus.Graph
  alias Argus.ReviewedFindings.Proof
  alias Roux.Input

  @program :project

  @typedoc """
  The project a run analyzes: where it is (`root`, the `project_root`
  input: where a beam compiled elsewhere finds its source) and where its
  state lives (`state_dir`, the manifest's directory). A frontend's
  project adapter builds it; a Mix project's is `mix_project/0`.
  """
  @type project :: %{
          required(:root) => Path.t(),
          required(:state_dir) => Path.t(),
          optional(atom()) => term()
        }

  @doc """
  The current Mix project (`Argus.Project.Mix.current/0`): its directory,
  its ebins, and its manifest path for state.
  """
  @spec mix_project() :: project()
  def mix_project, do: Argus.Project.Mix.current()

  @doc """
  The manifest the graph is kept in between runs, in the project's state
  directory: shared by `mix compile.argus` and `mix argus`, one
  incremental state whichever entry point drives it.
  """
  @spec manifest_file(project()) :: String.t()
  def manifest_file(project \\ mix_project()), do: Path.join(project.state_dir, "compile.argus")

  @doc "The files a run keeps in the project's state directory: the manifest."
  @spec state_files(project()) :: [String.t()]
  def state_files(project \\ mix_project()), do: [manifest_file(project)]

  @doc """
  Runs the configured analyses against the project's compiled beams.

  ## Options

    * `:project` — the project (`t:project/0`: an `Argus.Project`, whose
      program's and dependencies' ebins the scan reads), default the
      current Mix project;
    * `:manifest` — the manifest to keep the graph in, default
      `manifest_file/1`;
    * `:store` — the blob store, default `Argus.Graph.store/0`;
    * `:review_records` — exact decoded JSON review records. The Driver itself
      produces the current complete proof and validates each applied record.
      Never supply an externally constructed proof or disposition.
    * `:review_file` — path/hash provenance returned by ReviewedFindings.File.
    * `:review_proof` — opt into a complete native review proof (default false).
      Proof alone does not exempt a finding. Configured exact records select
      dispositions only after complete native proof. Missing source or degraded
      input raises instead of producing a reviewable certificate.
    * `:force` — start cold, ignoring the manifest (it is written
      afresh).
  """
  @spec run(Argus.Config.t(), keyword()) :: Result.t()
  def run(%Argus.Config{} = config, opts) do
    project = Keyword.get_lazy(opts, :project, &mix_project/0)
    manifest = Keyword.get_lazy(opts, :manifest, fn -> manifest_file(project) end)
    force? = Keyword.get(opts, :force, false)

    records =
      case Keyword.fetch(opts, :review_records) do
        :error -> nil
        {:ok, values} -> Argus.ReviewedFindings.records!(values)
      end

    review? = Keyword.get(opts, :review_proof, false)
    unless is_boolean(review?), do: raise(ArgumentError, "review_proof must be boolean")
    review? = review? or not is_nil(records)
    inventory = if review?, do: Proof.inventory!(project)

    session = Graph.open(store: Keyword.get(opts, :store), manifest: manifest, force: force?)
    # The session ends with the run, which solves each program once.
    :ok = Argus.FlowLog.Pool.keep(session.db.supervisor, false)

    try do
      db = session.db

      %{modules: discovered, ignored: ignored, duplicates: duplicates} =
        Argus.Project.Scan.scan(config, project)

      files =
        Map.new(Map.values(discovered) ++ Map.values(ignored), fn path ->
          path = Path.expand(path)
          {path, path}
        end)

      %{meta: meta} =
        Roux.Sources.sync(db, :beam, files, session.sources,
          hash: &Graph.hash/1,
          value: fn %{hash: hash} -> %{hash: hash} end
        )

      # A beam deleted between the scan and the sync is not part of the
      # project this run.
      keys =
        discovered
        |> Map.values()
        |> Enum.map(&Path.expand/1)
        |> Enum.filter(&Map.has_key?(meta, &1))
        |> Enum.sort()

      :ok = Input.set(db, :program, @program, keys)

      _moved =
        Graph.set_environment(db,
          project_root: project.root,
          # Every beam there is an input (`discovered` and `ignored`).
          own_ebins: Enum.map(project.apps, &elem(&1, 1)),
          # The specs of the modules the program calls are read from
          # the project's own ebins and the installed OTP, never from
          # the VM's code path.
          specs_source: Argus.Specs.Source.new(project)
        )

      solver? = Argus.FlowLog.available?()

      {located, notices} =
        if solver? do
          :ok = Graph.set_priors(db, @program, config.priors)
          located = Graph.located(db, @program, config.analyses)
          {located, extraction_notices(db, discovered) ++ points_to_notices(db)}
        else
          {%{}, [:engine_unavailable]}
        end

      review =
        if review? do
          Proof.capture!(
            db,
            @program,
            config,
            project,
            inventory,
            meta,
            located,
            notices ++ Enum.map(duplicates, &{:duplicate, &1})
          )
        end

      {located, review} = apply_reviews(located, review, records, opts[:review_file])
      changed? = force? or moved?(session)
      {_status, _session} = Roux.Session.commit(session, meta)
      _ = collect(session.blob)

      %Result{
        located: located,
        notices: notices ++ Enum.map(duplicates, &{:duplicate, &1}),
        changed?: changed?,
        review: review
      }
    after
      Roux.Session.close(session)
    end
  end

  defp apply_reviews(located, review, nil, _file), do: {located, review}

  defp apply_reviews(located, review, records, file) do
    raw =
      for {name, analysis} <- Enum.sort(review.analyses),
          finding <- analysis.findings,
          do: {name, finding}

    candidates =
      Enum.map(raw, fn {_name, finding} ->
        Argus.ReviewedFindings.candidate(finding.review_identity, review.proof)
      end)

    matched = Argus.ReviewedFindings.match!(candidates, records)
    grouped = Enum.zip(raw, matched) |> Enum.group_by(fn {{name, _finding}, _match} -> name end)

    placed =
      Map.new(located, fn {name, {:ok, values}} ->
        enriched = Map.get(grouped, name, [])

        original =
          Enum.map(enriched, fn {{_name, finding}, _match} ->
            Map.delete(finding, :review_identity)
          end)

        unless Enum.map(values, & &1.finding) == original,
          do: raise(ArgumentError, "argus review: native raw finding association differs")

        annotated =
          Enum.zip_with(values, enriched, fn location, {{_name, finding}, match} ->
            disposition =
              match |> Map.put(:native_severity, finding.severity) |> Map.put(:file, file)

            %{location | finding: Map.put(location.finding, :review, disposition)}
          end)

        {name, {:ok, annotated}}
      end)

    {placed, Map.merge(review, %{records: records, file: file})}
  end

  # Whether the run moved an input or computed an entry the manifest
  # does not hold. The manifest is also rewritten for a beam whose stamp
  # alone moved (a touch, or one read again once its stamp can be
  # trusted), and for the entries it drops: nothing found moves with it.
  defp moved?(%Roux.Session{restored?: false}), do: true

  defp moved?(%Roux.Session{db: db} = session) do
    Roux.Revision.current(db.revision) != session.revision or
      Roux.Database.writes(db) != session.writes
  end

  # What extraction could not do: each module it could not read at all
  # (named as the scan found its beam: nothing in it says which module it
  # is), and each step it recorded as failing on a module.
  defp extraction_notices(db, discovered) do
    by_path = Map.new(discovered, fn {module, path} -> {Path.expand(path), module} end)

    for error <- Graph.Findings.extraction_errors(db, @program) do
      module = error.module || Map.get(by_path, error.source)
      name = if error.module == nil and module != nil, do: inspect(module), else: error.source

      {:extraction_error, %{module: module, name: name, step: error.step, reason: error.reason}}
    end
  end

  # The points-to stage ran bounded, when an analysis read it: the
  # leaves its coarse pass resolved.
  defp points_to_notices(db) do
    case Roux.Memo.get(db, {:stage, {@program, :points_to}}) do
      {:ok, %Roux.Memo.Entry{value: {:ok, %{mode: {:bounded, leaves}}}}} ->
        [{:points_to_bounded, leaves}]

      _ ->
        []
    end
  end

  # The store, collected when a day has passed since its last collection
  # and no other run is collecting it (`Roux.Blob.maybe_gc/2`): what no
  # manifest retains, untouched for a day, and traces and kept solves
  # unused for a week. Every frontend runs here, so a store in use is
  # collected by the runs that use it; a temporary one goes as it
  # closes.
  defp collect(%Roux.Blob{temporary?: true}), do: :skipped
  defp collect(%Roux.Blob{} = store), do: Roux.Blob.maybe_gc(store)
end
