defmodule Argus.Graph.SelectedExtractionTest.RenamedStage do
  @behaviour Argus.Analysis

  @impl Argus.Analysis
  @spec name() :: atom()
  def name, do: :renamed_stage

  @impl Argus.Analysis
  @spec description() :: String.t()
  def description, do: "Read a staged relation through an explicit filename"

  @impl Argus.Analysis
  @spec rules_file() :: Path.t()
  def rules_file, do: Path.expand("../../fixtures/renamed_stage_input.dl", __DIR__)

  @impl Argus.Analysis
  @spec extractors() :: [module()]
  def extractors, do: []

  @impl Argus.Analysis
  @spec output_relations() :: [Argus.Analysis.output_relation()]
  def output_relations do
    [%{name: :stage_probe, fields: [{:proc, :symbol, "process"}], doc: "Resolved process."}]
  end
end

defmodule Argus.Graph.SelectedExtractionTest do
  use ExUnit.Case, async: true

  alias __MODULE__.RenamedStage
  alias Argus.Graph
  alias Argus.Graph.Extraction
  alias Argus.Test.Graph, as: TestGraph
  alias Roux.{Blob, Runtime, Session}

  @moduletag :flowlog
  @moduletag :tmp_dir

  test "selection extracts only declared producers and native input providers" do
    session = Graph.open(store: Blob.temporary())

    try do
      Graph.set_environment(session.db, analyses: [:exunit_tmp_dir], stamps: false)

      assert producers(session.db) ==
               Enum.sort([
                 :base,
                 Argus.Extractors.ClauseCall,
                 Argus.Extractors.TempDirectories,
                 Argus.Extractors.Tooling
               ])

      refute Argus.Extractors.ETS in producers(session.db)
      refute Argus.Extractors.TermFlow in producers(session.db)
    after
      Session.close(session)
    end
  end

  test "selection changes survive manifest restoration without losing broad facts", %{
    tmp_dir: dir
  } do
    path = Argus.Test.Fixtures.ExUnitTmpDir.Helpers |> :code.which() |> to_string()
    store = Blob.open!(Path.join(dir, "store"))
    manifest = Path.join(dir, "manifest")

    narrow = snapshot(store, manifest, path, [:exunit_tmp_dir])
    broad = snapshot(store, manifest, path, :all)
    assert Enum.sort(Map.keys(broad.producers)) == Enum.sort(Extraction.producers())
    assert Map.has_key?(broad.producers, Argus.Extractors.ETS)
    assert narrow == snapshot(store, manifest, path, [:exunit_tmp_dir])
    assert broad == snapshot(store, manifest, path, :all)
  end

  test "raw custom programs retain the full inventory", %{tmp_dir: dir} do
    # The missing rule is intentional: selection must not run a solver or
    # guess an ad-hoc program's extractor contract to preserve its facts.
    session = Graph.open(store: Blob.temporary())

    try do
      Graph.set_environment(session.db,
        analyses: [{:custom, Path.join(dir, "custom.dl")}],
        stamps: false
      )

      assert producers(session.db) == Enum.sort(Extraction.producers())
    after
      Session.close(session)
    end
  end

  test "coverage retains every producer whose uncertainty it measures" do
    session = Graph.open(store: Blob.temporary())

    try do
      for analysis <- [:coverage, Argus.Analyses.Coverage, {Argus.Analyses.Coverage, []}] do
        Graph.set_environment(session.db, analyses: [analysis], stamps: false)
        assert producers(session.db) == Enum.sort(Extraction.producers())
      end
    after
      Session.close(session)
    end
  end

  test "renamed staged input filenames retain their native stage producers" do
    module = Argus.Test.Fixtures.PidFlow.Hub
    db = TestGraph.new_db(%{module => module |> :code.which() |> to_string()}, store: :temporary)

    try do
      Graph.set_environment(db, analyses: [RenamedStage], stamps: false)
      selected = producers(db)
      assert Argus.Extractors.TermFlow in selected
      assert Argus.Extractors.OTP in selected
      refute Argus.Extractors.TempDirectories in selected

      assert {:ok, %{"stage_probe" => [_ | _]} = narrow} =
               Graph.Findings.results(db, :test, RenamedStage)

      Graph.set_environment(db, stamps: false)
      assert {:ok, broad} = Graph.Findings.results(db, :test, RenamedStage)
      assert narrow == broad
    after
      Roux.Database.shutdown(db)
    end
  end

  @tag :parity
  @tag timeout: 600_000
  test "each built-in selection has the same findings as the full producer inventory" do
    paths = TestGraph.parity!()
    db = TestGraph.new_db(paths, store: :temporary)
    {:ok, analyses} = Argus.Analysis.set(:all)

    try do
      # Solve broadly first. Reusing this same graph checks both that changing
      # the producer input invalidates packs and that added stages are complete.
      broad = TestGraph.incremental(db, analyses)

      for analysis <- analyses do
        assert {:ok, _} = Map.fetch!(broad, analysis)
        Graph.set_environment(db, analyses: [analysis], stamps: false)

        assert TestGraph.incremental(db, [analysis]) == Map.take(broad, [analysis]),
               "#{analysis}: selected extraction differs from full extraction"
      end

      Graph.set_environment(db, stamps: false)
      assert TestGraph.incremental(db, analyses) == broad
    after
      Roux.Database.shutdown(db)
    end
  end

  defp producers(db), do: Runtime.query(db, :producer_code, :all) |> Map.keys() |> Enum.sort()

  defp snapshot(store, manifest, path, selection) do
    session = Graph.open(store: store, manifest: manifest)

    try do
      Graph.set_program(session.db, :test, [path])
      opts = if selection == :all, do: [], else: [analyses: selection]
      Graph.set_environment(session.db, Keyword.put(opts, :stamps, false))
      assert {:ok, pack} = Extraction.module_facts(session.db, Path.expand(path))
      {_status, _session} = Session.commit(session, %{})
      %{pack: pack, producers: Runtime.query(session.db, :producer_code, :all)}
    after
      Session.close(session)
    end
  end
end
