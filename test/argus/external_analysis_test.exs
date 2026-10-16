defmodule Argus.ExternalAnalysisTest do
  use ExUnit.Case, async: true

  alias Argus.Test.{ExternalAnalysis, MissingExternalAnalysis}
  @moduletag :flowlog
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  setup %{tmp_dir: dir} do
    own = Path.join(dir, "app/ebin")
    dep = Path.join(dir, "dependency/ebin")
    File.mkdir_p!(own)
    File.mkdir_p!(dep)
    beam!(:external_owner, Path.join(own, "external_owner.beam"), [])

    beam!(:external_reference, Path.join(dep, "external_reference.beam"), [
      {:attribute, 3, :external_value, :first}
    ])

    project = %Argus.Project{
      kind: :beams,
      root: dir,
      apps: [external: own],
      deps: [dependency: dep],
      state_dir: Path.join(dir, "state")
    }

    %{
      project: project,
      store: Roux.Blob.open!(Path.join(dir, "store")),
      reference: Path.join(dep, "external_reference.beam")
    }
  end

  test "native Driver composes builtin and external modules, policy and Findings", context do
    selection = {ExternalAnalysis, value: "first"}

    config =
      Argus.Config.load(
        analyses: [:coupling, selection],
        severity: [external_analysis: :error],
        ignore: [findings: [{:external_analysis, :external_owner}]]
      )

    cold = Argus.Driver.run(config, project: context.project, store: context.store)
    assert cold.notices == []
    assert {:ok, []} = cold.located.coupling
    assert {:ok, [located]} = cold.located[selection]
    assert located.finding.analysis == :external_analysis
    assert located.finding.title == "External value first"
    assert config.ignore_findings == [{:external_analysis, :external_owner}]
    assert Argus.Report.build(cold.located, config, context.project.root) == []
    warm = Argus.Driver.run(config, project: context.project, store: context.store)
    refute warm.changed?
    assert warm.located == cold.located
    assert :code.is_loaded(:external_owner) == false
    assert :code.is_loaded(:external_reference) == false
  end

  test "referenced BEAM changes and lookup absence invalidate a warm graph", context do
    run = fn value ->
      selection = {ExternalAnalysis, value: value}

      result =
        Argus.Driver.run(Argus.Config.load(analyses: [selection]),
          project: context.project,
          store: context.store
        )

      assert result.notices == []
      assert {:ok, [located]} = result.located[selection]
      assert located.finding.title == "External value #{value}"
    end

    run.("first")
    beam!(:external_reference, context.reference, [{:attribute, 3, :external_value, :second}])
    run.("second")
    File.rm!(context.reference)
    missing = {ExternalAnalysis, value: "second"}

    failed =
      Argus.Driver.run(Argus.Config.load(analyses: [:coupling, missing]),
        project: context.project,
        store: context.store
      )

    assert {:ok, []} = failed.located.coupling
    assert {:ok, []} = failed.located[missing]
    assert Argus.Driver.Result.degraded(failed) == []
    assert Argus.Driver.Result.incomplete?(failed)

    assert [
             {:required_module_input,
              %{analysis: ^missing, module: :external_reference, reason: :missing}}
           ] = failed.notices

    config = Argus.Config.load(analyses: [:coupling, missing])
    notices = Argus.Report.Notice.from_result(failed, config, context.project.root)
    assert [%{severity: :error, message: message}] = notices
    assert message =~ "partial results"
    refute message =~ "reported nothing"

    ExUnit.CaptureIO.capture_io(fn ->
      result =
        Argus.CLI.report(
          failed,
          [],
          config,
          %Argus.CLI.Options{format: :json, fail_above: 0},
          context.project.root,
          context.project.root
        )

      assert result.entries == []
      assert result.status == 3
    end)

    stable = Argus.Driver.run(config, project: context.project, store: context.store)
    refute stable.changed?
    assert stable.located == failed.located
    assert stable.notices == failed.notices
    beam!(:external_reference, context.reference, [{:attribute, 3, :external_value, :second}])
    recovered = Argus.Driver.run(config, project: context.project, store: context.store)
    refute Argus.Driver.Result.incomplete?(recovered)
    assert recovered.notices == []
    assert {:ok, [located]} = recovered.located[missing]
    assert located.finding.title == "External value second"
    assert :code.is_loaded(:external_reference) == false
  end

  test "external options, included rules and analyzer code invalidate only real changes",
       context do
    root = context.project.root
    rules = Path.join(root, "main.dl")
    included = Path.join(root, "body.dl")
    original = File.read!(ExternalAnalysis.rules_file())
    File.write!(rules, ~s(.include "body.dl"\n))
    File.write!(included, original)
    ebin = Path.join(root, "analyzer/ebin")
    File.mkdir_p!(ebin)
    module = Module.concat(__MODULE__, "Selected#{System.unique_integer([:positive])}")
    external_analysis!(module, rules, ebin, "")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    beams = [
      context.reference,
      Path.join(elem(hd(context.project.apps), 1), "external_owner.beam")
    ]

    before = Map.new(beams, &{&1, File.read!(&1)})

    run = fn value ->
      selection = {module, value: value}
      config = Argus.Config.load(analyses: [selection])
      result = Argus.Driver.run(config, project: context.project, store: context.store)
      assert result.notices == []
      assert Argus.Driver.Result.degraded(result) == []
      {selection, config, result}
    end

    {first, _, cold} = run.("first")
    assert {:ok, [_]} = cold.located[first]
    {_, _, stable} = run.("first")
    refute stable.changed?

    {second, config, options_changed} = run.("second")
    assert options_changed.changed?
    assert {:ok, []} = options_changed.located[second]
    {_, _, stable} = run.("second")
    refute stable.changed?

    File.write!(
      included,
      String.replace(
        original,
        "external_value(m,v),external_policy(v)",
        "external_value(m,_),external_policy(v)"
      )
    )

    {_, _, rules_changed} = run.("second")
    assert rules_changed.changed?
    assert {:ok, [located]} = rules_changed.located[second]
    assert located.finding.title == "External value second"

    external_analysis!(module, rules, ebin, "Updated ")
    # Roux freezes analyzer code per VM. This explicit test reload models a
    # fresh CLI code identity while preserving the native graph/result store.
    Roux.Code.forget()
    {_, _, code_changed} = run.("second")
    assert code_changed.changed?
    assert {:ok, [located]} = code_changed.located[second]
    assert located.finding.title == "Updated External value second"

    fresh =
      Argus.Driver.run(config,
        project: context.project,
        store: context.store,
        manifest: Path.join(root, "fresh.manifest")
      )

    assert fresh.located == code_changed.located
    {_, _, unchanged} = run.("second")
    refute unchanged.changed?
    assert unchanged.located == code_changed.located
    assert before == Map.new(beams, &{&1, File.read!(&1)})
  end

  test "a missing external main degrades only its selection", context do
    selection = {ExternalAnalysis, value: "first"}
    missing = {MissingExternalAnalysis, []}
    config = Argus.Config.load(analyses: [selection, missing])
    result = Argus.Driver.run(config, project: context.project, store: context.store)
    assert {:ok, [_]} = result.located[selection]
    assert {:error, {:rules_not_found, _}} = result.located[missing]
    assert [%{analysis: ^missing}] = Argus.Driver.Result.degraded(result)
    assert [_notice] = Argus.Report.Notice.from_result(result, config, context.project.root)
  end

  test "policy inputs reject producer and stage overwrites but retain unused declarations",
       context do
    for relation <- [:external_value, :function_def, :call_edge] do
      selection = {ExternalAnalysis, value: "first", facts: %{relation => []}}

      result =
        Argus.Driver.run(Argus.Config.load(analyses: [selection]),
          project: context.project,
          store: context.store
        )

      assert {:error, {:analysis_inputs, message}} = result.located[selection]
      assert message =~ "cannot overwrite"
    end

    selection =
      {ExternalAnalysis,
       value: "first", facts: %{external_policy: [["first"]], unused_policy: [["unused"]]}}

    result =
      Argus.Driver.run(Argus.Config.load(analyses: [selection]),
        project: context.project,
        store: context.store
      )

    assert {:ok, [_]} = result.located[selection]
  end

  test "explicit selection preserves options and rejects reporting identity collisions" do
    assert Argus.Config.load(analyses: [{ExternalAnalysis, value: "first"}]).analyses == [
             {ExternalAnalysis, value: "first"}
           ]

    assert_raise Argus.ConfigError, fn ->
      Argus.Config.load(analyses: [ExternalAnalysis, {ExternalAnalysis, value: "first"}])
    end

    assert_raise Argus.ConfigError, fn ->
      Argus.Config.load(analyses: [{ExternalAnalysis, [value: "first", value: "second"]}])
    end
  end

  test "native inputs preserve project/reference roles and bound cyclic declarations", context do
    selection = {ExternalAnalysis, value: "first"}
    config = Argus.Config.load(analyses: [:coupling, selection])
    manifest = Path.join(context.project.root, "references.manifest")

    result =
      Argus.Driver.run(config, project: context.project, store: context.store, manifest: manifest)

    assert result.notices == []
    session = Argus.Graph.open(store: context.store, manifest: manifest)

    try do
      program = Argus.Graph.analysis_program(session.db, :project, selection)
      assert program != :project
      assert Argus.Graph.analysis_program(session.db, :project, :coupling) == :project

      assert Enum.sort(Argus.Graph.Relations.rows(session.db, program, :external_role)) == [
               [":external_owner", "project"],
               [":external_reference", "reference"]
             ]
    after
      Roux.Session.close(session)
    end

    unchanged =
      Argus.Driver.run(config, project: context.project, store: context.store, manifest: manifest)

    refute unchanged.changed?
    assert unchanged.located == result.located
  end

  test "a reference declaration failure degrades only its selection", context do
    beam!(:external_reference, context.reference, [
      {:attribute, 3, :external_reference_fail, true}
    ])

    selection = {ExternalAnalysis, value: "first"}

    result =
      Argus.Driver.run(Argus.Config.load(analyses: [:coupling, selection]),
        project: context.project,
        store: context.store
      )

    assert {:ok, []} = result.located.coupling

    assert {:error, {:required_module_inputs, {:reference_declaration, ArgumentError}}} =
             result.located[selection]

    assert [%{analysis: ^selection}] = Argus.Driver.Result.degraded(result)
  end

  test "referenced producer failures remain native extraction notices", context do
    beam!(:external_reference, context.reference, [{:attribute, 3, :external_fail, true}])
    selection = {ExternalAnalysis, value: "first"}

    result =
      Argus.Driver.run(Argus.Config.load(analyses: [:coupling, selection]),
        project: context.project,
        store: context.store
      )

    assert {:ok, []} = result.located.coupling

    assert Enum.any?(result.notices, fn
             {:extraction_error, %{module: :external_reference, reason: reason}} ->
               String.contains?(reason, "referenced fixture producer failed")

             _ ->
               false
           end)
  end

  test "native extraction never invokes a persisted debug backend", context do
    path = Path.join(elem(hd(context.project.apps), 1), "external_owner.beam")
    {:ok, :external_owner, chunks} = :beam_lib.all_chunks(String.to_charlist(path))

    payload =
      :erlang.term_to_binary({:debug_info_v1, Argus.Test.ExternalDebugBackend, {:probe, self()}})

    chunks =
      Enum.map(chunks, fn
        {~c"Dbgi", _} -> {~c"Dbgi", payload}
        chunk -> chunk
      end)

    {:ok, bytes} = :beam_lib.build_module(chunks)
    File.write!(path, bytes)
    source = Argus.Specs.Source.new([Path.dirname(path)])
    _digest = Argus.Specs.interface_digest(:external_owner, source)
    selection = {ExternalAnalysis, value: "first"}

    result =
      Argus.Driver.run(Argus.Config.load(analyses: [selection]),
        project: context.project,
        store: context.store
      )

    assert {:ok, [_]} = result.located[selection]

    assert Enum.any?(result.notices, fn
             {:extraction_error, %{step: "Argus.Extractors.Generated", reason: reason}} ->
               reason =~ "unsupported debug information"

             _ ->
               false
           end)

    refute_received :external_debug_backend_executed
    assert :code.is_loaded(:external_owner) == false
  end

  defp external_analysis!(module, rules, ebin, prefix) do
    :code.purge(module)
    :code.delete(module)

    quoted =
      quote do
        @behaviour Argus.Analysis
        @impl true
        def name, do: :external_edit_analysis
        @impl true
        def description, do: "An isolated external identity fixture"
        @impl true
        def rules_file, do: unquote(rules)
        @impl true
        def extractors, do: Argus.Test.ExternalAnalysis.extractors()
        @impl true
        def input_facts(options), do: Argus.Test.ExternalAnalysis.input_facts(options)
        @impl true
        def output_relations, do: Argus.Test.ExternalAnalysis.output_relations()
        @impl true
        def finding(relation, row) do
          attrs = Argus.Test.ExternalAnalysis.finding(relation, row)
          %{attrs | title: unquote(prefix) <> attrs.title}
        end
      end

    {:module, ^module, bytes, _} = Module.create(module, quoted, Macro.Env.location(__ENV__))
    path = Path.join(ebin, Atom.to_string(module) <> ".beam")
    File.write!(path, bytes)
    :code.purge(module)
    :code.delete(module)
    {:module, ^module} = path |> Path.rootname() |> String.to_charlist() |> :code.load_abs()
  end

  defp beam!(module, path, attributes) do
    forms =
      [{:attribute, 1, :module, module}, {:attribute, 2, :export, [run: 0]}] ++
        attributes ++
        [{:function, 4, :run, 0, [{:clause, 4, [], [], [{:atom, 4, :ok}]}]}]

    {:ok, ^module, bytes} = :compile.forms(forms, [:binary, :debug_info])
    File.write!(path, bytes)
  end
end
