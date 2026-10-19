defmodule Argus.Graph.ApplicationTest.Probe do
  @behaviour Argus.Extractor
  @impl Argus.Extractor
  @spec relations() :: [atom()]
  def relations, do: [:application_probe]
  @impl Argus.Extractor
  @spec extract(data :: Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(data), do: %{application_probe: [[to_string(data.application)]]}
end

defmodule Argus.Graph.ApplicationTest.BeamProbe do
  @behaviour Argus.Extractor
  @impl Argus.Extractor
  @spec requirements() :: [atom()]
  def requirements, do: [:beam]
  @impl Argus.Extractor
  @spec relations() :: [atom()]
  def relations, do: [:application_probe]
  @impl Argus.Extractor
  @spec extract(data :: Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(%{beam: <<"FOR1", _::binary>>} = data),
    do: %{application_probe: [[to_string(data.application)]]}
end

defmodule Argus.Graph.ApplicationTest.Analysis do
  @behaviour Argus.Analysis
  @impl Argus.Analysis
  @spec name() :: atom()
  def name, do: :application_probe
  @impl Argus.Analysis
  @spec description() :: String.t()
  def description, do: "Probe native application identity"
  @impl Argus.Analysis
  @spec rules_file() :: Path.t()
  def rules_file, do: Argus.Dl.path("analyses/coupling.dl")
  @impl Argus.Analysis
  @spec extractors() :: [module()]
  def extractors, do: [Argus.Graph.ApplicationTest.Probe, Argus.Graph.ApplicationTest.BeamProbe]
  @impl Argus.Analysis
  @spec output_relations() :: [Argus.Analysis.output_relation()]
  def output_relations, do: []
end

defmodule Argus.Graph.ApplicationTest do
  use ExUnit.Case, async: true

  alias Argus.Graph
  alias Roux.{Blob, Runtime, Session}

  @moduletag :tmp_dir

  test "native extractor inputs retain frontend application identity and invalidate on remapping",
       %{tmp_dir: dir} do
    own = Path.join(dir, "own")
    dependency = Path.join(dir, "dependency")
    own_path = beam!(own, :application_owner)
    dependency_path = beam!(dependency, :application_dependency)
    session = Graph.open(store: Blob.temporary())

    try do
      Graph.set_program(session.db, :project, [own_path, dependency_path])

      environment = [
        analyses: [__MODULE__.Analysis],
        own_ebins: [own],
        application_ebins: [own_app: own, library_app: dependency],
        stamps: false
      ]

      Graph.set_environment(session.db, environment)

      assert {:ok, %{application: :own_app, project?: true}} =
               Runtime.query(session.db, :extraction_metadata, own_path)

      assert {:ok, %{application: :library_app, project?: false}} =
               Runtime.query(session.db, :extraction_metadata, dependency_path)

      for producer <- [__MODULE__.Probe, __MODULE__.BeamProbe] do
        assert {:ok, %{application_probe: "own_app\n"}} =
                 Runtime.query(session.db, :extraction_producer, {own_path, producer})
      end

      Graph.set_environment(
        session.db,
        Keyword.put(environment, :application_ebins, renamed_app: own, library_app: dependency)
      )

      for producer <- [__MODULE__.Probe, __MODULE__.BeamProbe] do
        assert {:ok, %{application_probe: "renamed_app\n"}} =
                 Runtime.query(session.db, :extraction_producer, {own_path, producer})
      end
    after
      Session.close(session)
    end
  end

  test "in-memory inputs have no guessed application", %{tmp_dir: dir} do
    path = beam!(dir, :application_memory)
    session = Graph.open(store: Blob.temporary())

    try do
      [key] = Graph.set_program(session.db, :project, [File.read!(path)])
      Graph.set_environment(session.db, application_ebins: [not_the_owner: dir], stamps: false)
      assert {:ok, %{application: nil}} = Runtime.query(session.db, :extraction_metadata, key)
    after
      Session.close(session)
    end
  end

  defp beam!(directory, module) do
    File.mkdir_p!(directory)

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 2, :export, [value: 0]},
      {:function, 3, :value, 0, [{:clause, 3, [], [], [{:integer, 3, 1}]}]}
    ]

    {:ok, ^module, binary} = :compile.forms(forms, [:binary, :debug_info])
    path = Path.join(directory, Atom.to_string(module) <> ".beam")
    File.write!(path, binary)
    path
  end
end
