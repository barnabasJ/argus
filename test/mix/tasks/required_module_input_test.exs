defmodule Mix.Tasks.Argus.RequiredModuleInputTest do
  @moduledoc """
  Real Mix task and compiler frontends reject missing required module inputs
  even when the native Driver returns zero Findings. Ordinary extraction
  warnings keep their existing default behavior. Fixture compilation, Mix
  state and code paths stay inside this module's peer.
  """
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Test.{ExternalAnalysis, Fixture, Peer}
  import ExUnit.CaptureIO

  @moduletag :project
  @moduletag :flowlog
  @moduletag :tmp_dir
  @moduletag timeout: 300_000
  @selection {ExternalAnalysis, value: "unmatched-policy"}
  @config [analyses: [@selection], engine: :require]

  setup_all do
    %{peer: Peer.start!(store: :own, env: [{"MIX_BUILD_PATH", nil}])}
  end

  test "mix argus raises for an incomplete required input after reporting zero Findings",
       context do
    app = :depot_required_input_task
    copy = Fixture.checkout!(Path.join(context.tmp_dir, "project"), @config, app)

    Fixture.in_peer(context.peer, copy, app, fn _log ->
      reference = complete_project!()
      File.rm!(reference)
      assert_missing_required_input!()
      Mix.Task.clear()

      {{error, json}, stderr} =
        with_io(:stderr, fn ->
          with_io(fn ->
            assert_raise Mix.Error,
                         "argus: required module inputs are unavailable; results are incomplete",
                         fn ->
                           Mix.Task.rerun("argus", ["--format", "json", "--fail-above", "0"])
                         end
          end)
        end)

      assert error.__struct__ == Mix.Error
      assert JSON.decode!(json) == []
      assert stderr =~ "required module input :external_reference is missing"
      refute stderr =~ "findings exceed"
      assert :code.is_loaded(:external_owner) == false
      assert :code.is_loaded(:external_reference) == false
    end)
  end

  test "the real compiler chain returns error solely for missing required input", context do
    app = :depot_required_input_compiler
    copy = Fixture.checkout!(Path.join(context.tmp_dir, "project"), @config, app)

    Fixture.in_peer(context.peer, copy, app, fn _log ->
      reference = complete_project!()
      File.rm!(reference)
      assert_missing_required_input!()

      assert {:error, diagnostics} = Fixture.compile!()
      assert [notice] = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))
      assert notice.severity == :error
      assert notice.position == 0
      assert notice.file == Path.join(File.cwd!(), "mix.exs")
      assert notice.message =~ "required module input :external_reference is missing"
      assert notice.message =~ "partial results"
      refute Enum.any?(diagnostics, &String.starts_with?(&1.message, "[argus."))
      assert_missing_required_input!()

      beam!(:external_reference, reference, [{:attribute, 3, :external_value, :first}])
      assert {:ok, diagnostics} = Fixture.compile!()
      assert Enum.filter(diagnostics, &(&1.compiler_name == "argus")) == []
      result = Argus.Driver.run(Argus.Config.load(), [])
      refute Argus.Driver.Result.incomplete?(result)
      assert result.notices == []
      assert {:ok, []} = result.located[@selection]
      assert :code.is_loaded(:external_reference) == false
    end)
  end

  test "ordinary extraction warnings do not become required-input failures", context do
    app = :depot_extraction_warning_frontends

    copy =
      Fixture.checkout!(
        Path.join(context.tmp_dir, "project"),
        [analyses: [:blocking], engine: :require],
        app
      )

    Fixture.in_peer(context.peer, copy, app, fn _log ->
      assert {:ok, diagnostics} = Fixture.compile!()
      assert Enum.filter(diagnostics, &(&1.compiler_name == "argus")) == []

      garbage = Path.join(Mix.Project.compile_path(), "Elixir.Depot.Garbage.beam")
      File.write!(garbage, "not a BEAM")

      try do
        result = Argus.Driver.run(Argus.Config.load(), [])
        assert {:ok, []} = result.located.blocking
        assert Argus.Report.build(result.located, Argus.Config.load(), File.cwd!()) == []
        refute Argus.Driver.Result.incomplete?(result)
        assert [{:extraction_error, %{name: "Depot.Garbage", step: "module"}}] = result.notices

        {status, diagnostics} = Fixture.compile!()
        refute status == :error
        assert [notice] = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))
        assert notice.severity == :warning
        assert notice.message =~ "Depot.Garbage could not be extracted"
        assert Enum.all?(diagnostics, &(&1.severity != :error))

        Mix.Task.clear()

        {{:ok, json}, stderr} =
          with_io(:stderr, fn ->
            with_io(fn -> Mix.Task.rerun("argus", ["--format", "json", "--fail-above", "0"]) end)
          end)

        assert JSON.decode!(json) == []
        assert stderr =~ "Depot.Garbage could not be extracted"
      after
        File.rm!(garbage)
      end
    end)
  end

  defp complete_project! do
    assert {:ok, diagnostics} = Fixture.compile!()
    assert Enum.filter(diagnostics, &(&1.compiler_name == "argus")) == []
    beam!(:external_owner, Path.join(Mix.Project.compile_path(), "external_owner.beam"), [])
    dependency = Path.join([Mix.Project.build_path(), "lib", "frontend_dependency", "ebin"])
    File.mkdir_p!(dependency)
    reference = Path.join(dependency, "external_reference.beam")
    beam!(:external_reference, reference, [{:attribute, 3, :external_value, :first}])
    assert {:ok, diagnostics} = Fixture.compile!()
    assert Enum.filter(diagnostics, &(&1.compiler_name == "argus")) == []
    result = Argus.Driver.run(Argus.Config.load(), [])
    assert result.notices == []
    refute Argus.Driver.Result.incomplete?(result)
    assert {:ok, []} = result.located[@selection]
    assert Argus.Report.build(result.located, Argus.Config.load(), File.cwd!()) == []
    reference
  end

  defp assert_missing_required_input! do
    result = Argus.Driver.run(Argus.Config.load(), [])
    assert {:ok, []} = result.located[@selection]
    assert Argus.Report.build(result.located, Argus.Config.load(), File.cwd!()) == []
    assert Argus.Driver.Result.degraded(result) == []
    assert Argus.Driver.Result.incomplete?(result)

    assert [
             {:required_module_input,
              %{analysis: @selection, module: :external_reference, reason: :missing}}
           ] = result.notices

    result
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
