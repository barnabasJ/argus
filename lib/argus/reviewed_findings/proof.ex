defmodule Argus.ReviewedFindings.Proof do
  @moduledoc """
  The native Driver proof producer. It reads actual
  graph inputs, rule and producer digests, and all application/dependency source
  and BEAM content. It does not accept caller-supplied content hashes.

  Inventories are intentionally conservative: an unrelated dependency edit also
  requires a new review. Missing source, duplicates, degraded analyses, extraction
  notices, bounded points-to and unversioned code prevent a complete proof.
  """

  alias Argus.ReviewedFindings
  alias Roux.Runtime

  @doc "Read source and native canonical BEAM hashes before extraction."
  def inventory!(project) do
    roots = declared_roots!(project)

    entries =
      for {role, application, ebin} <- roots,
          {module, path} <- Argus.Project.Scan.discover([ebin], []).modules do
        bytes = File.read!(path)
        {:ok, {^module, chunks}} = :beam_lib.chunks(bytes, [:compile_info])
        info = Keyword.fetch!(chunks, :compile_info)
        source = info |> Keyword.fetch!(:source) |> to_string()
        source_bytes = source |> source_path(project.root) |> File.read!()
        root = Roux.Code.build_root(path) || project.root
        {:ok, portable} = Roux.Code.beam_digest(bytes, root: root, debug_info: true)

        {module,
         %{
           role: role,
           application: application,
           beam: Argus.Graph.hash(bytes),
           portable: Base.encode16(portable, case: :lower),
           source: sha(source_bytes)
         }}
      end

    modules = Enum.map(entries, &elem(&1, 0))
    unless length(modules) == length(Enum.uniq(modules)), do: invalid!("duplicate input modules")
    if modules == [], do: invalid!("empty module inventory")
    Map.new(entries)
  end

  @doc "Portable content inventory, retaining declared application and role identity."
  def certificate_inventory(inventory) do
    Map.new(inventory, fn {module, values} -> {module, Map.delete(values, :beam)} end)
  end

  defp declared_roots!(project) do
    roots =
      Enum.map(project.apps, fn {app, ebin} -> {:project, app, ebin} end) ++
        Enum.map(project.deps, fn {app, ebin} -> {:dependency, app, ebin} end)

    identities = Enum.map(roots, fn {role, app, _ebin} -> {role, app} end)

    unless length(identities) == length(Enum.uniq(identities)),
      do: invalid!("ambiguous declared application roots")

    roots
  end

  @doc """
  Capture actual semantic inputs before the Driver closes its graph session.
  The pre-run inventory must still match; all selected/ignored module hashes
  must agree with the actual native sync metadata. No report exemption is made.
  """
  def capture!(db, program, config, project, before, synced, located, notices) do
    unless notices == [] and Enum.all?(located, fn {_name, value} -> match?({:ok, _}, value) end) do
      invalid!("only a complete, exact run can produce review proof")
    end

    unless inventory!(project) == before, do: invalid!("inputs changed during analysis")

    selected =
      for {path, metadata} <- synced, into: %{} do
        module = path |> Path.basename(".beam") |> String.to_existing_atom()
        %{beam: actual} = Map.fetch!(before, module)
        unless actual == metadata.hash, do: invalid!("native sync and inventory disagree")
        {module, Map.take(Map.fetch!(before, module), [:application, :role, :portable])}
      end

    unless map_size(selected) > 0, do: invalid!("empty selected module universe")

    program_modules =
      for path <- Runtime.input(db, :program, program), into: %{} do
        module = path |> Path.basename(".beam") |> String.to_existing_atom()
        {module, Map.fetch!(selected, module)}
      end

    producers = Runtime.query(db, :producer_code, :all)
    unless is_map(producers) and map_size(producers) > 0, do: invalid!("missing producer code")
    Enum.each(producers, fn {_producer, digest} -> hash!(digest) end)

    analyses =
      for analysis <- config.analyses, into: %{} do
        {module, code} = Runtime.query(db, :analysis_code, analysis)
        hash!(code)
        {:ok, rules} = Runtime.query(db, :program_digest, analysis)
        hash!(rules)
        {:ok, inputs} = Runtime.query(db, :analysis_inputs, {program, analysis})
        {:ok, outputs} = Argus.Graph.Findings.results(db, program, analysis)
        census = Argus.ReviewedFindings.Identity.census!(module, outputs)
        {findings, failures} = Argus.Findings.Build.with_review_identity(module, outputs)
        unless failures == [], do: invalid!("finding or evidence builder failed")

        {analysis,
         %{
           module: module,
           code: code,
           rules: rules,
           inputs: Enum.sort(inputs),
           census: ReviewedFindings.digest(census),
           findings: findings
         }}
      end

    programs =
      for name <- Enum.uniq(config.analyses ++ [:stage0, :points_to, :points_to_bounded]),
          into: %{} do
        {:ok, files} = Runtime.query(db, :program_files, name)
        {name, Enum.sort(files)}
      end

    # Native code closures include extraction, schemas, source/spec readers and
    # the proof producer itself; rule and toolchain trees bind dynamic inputs.
    {:ok, driver_code} = Roux.Code.digest([Argus.Driver, __MODULE__], store: db.blob)
    hash!(driver_code)

    binding = %{
      version: 1,
      inventory: certificate_inventory(before),
      roots:
        Enum.map(declared_roots!(project), fn {role, app, _ebin} -> {role, app} end)
        |> Enum.sort(),
      selected: program_modules,
      synced: selected,
      programs: programs,
      producers: producers,
      analyses: Map.new(analyses, fn {name, values} -> {name, Map.delete(values, :findings)} end),
      driver_code: driver_code,
      policy: Argus.Config.analysis_policy(config),
      rules: Argus.Dl.Embedded.digest(),
      engine: Argus.FlowLog.Native.digest(),
      otp: System.otp_release(),
      erts: :erlang.system_info(:system_version),
      elixir: System.version()
    }

    proof = %{
      version: 1,
      complete?: true,
      digest: ReviewedFindings.digest(binding),
      binding: binding
    }

    %{proof: proof, analyses: analyses}
  end

  defp source_path(path, root) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end

  defp hash!(hash) when is_binary(hash) and byte_size(hash) == 64, do: :ok
  defp hash!(_hash), do: invalid!("unversioned or missing code proof")
  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  defp invalid!(message), do: raise(ArgumentError, "argus review proof: " <> message)
end
