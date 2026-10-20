defmodule Mix.Tasks.ArgusTestCaptureTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  import ExUnit.CaptureIO

  alias Argus.Mix.TestCapture
  alias Argus.Project.Mix, as: MixProject
  alias Argus.Project.Scan
  alias Argus.Test.MissingExternalAnalysis
  alias Argus.Test.Peer
  alias Mix.Tasks.Argus.Test

  @moduletag :project
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "captures helper and test modules without executing test or setup bodies", %{tmp_dir: root} do
    fixture!(root)
    snapshot = capture!(root, [])

    assert snapshot.modules[CaptureFixture.Helper]
    assert snapshot.modules[CaptureFixture.Support]
    assert snapshot.modules[CaptureFixture.FirstTest]
    assert snapshot.modules[CaptureFixture.SecondTest]
    assert snapshot.debug_info
    assert snapshot.helper_debug_info
    assert snapshot.source == Path.join(root, "test/first_test.exs")
    assert snapshot.initialized
    refute File.exists?(Path.join(root, "body-ran"))
    refute File.exists?(snapshot.directory)
  end

  test "changed and deleted tests cannot survive the next capture", %{tmp_dir: root} do
    fixture!(root)
    assert capture!(root, []).modules[CaptureFixture.FirstTest]
    File.rm!(Path.join(root, "test/second_test.exs"))
    File.write!(Path.join(root, "test/first_test.exs"), test_source(CaptureFixture.RenamedTest))
    snapshot = capture!(root, [])
    assert snapshot.modules[CaptureFixture.RenamedTest]
    refute snapshot.modules[CaptureFixture.FirstTest]
    refute snapshot.modules[CaptureFixture.SecondTest]
  end

  test "a partial native test selection captures only selected tests", %{tmp_dir: root} do
    fixture!(root)
    snapshot = capture!(root, ["test/second_test.exs"])
    assert snapshot.modules[CaptureFixture.SecondTest]
    assert snapshot.modules[CaptureFixture.Helper]
    refute snapshot.modules[CaptureFixture.FirstTest]
  end

  test "a native file separator cannot disable the dry run", %{tmp_dir: root} do
    fixture!(root)

    for arguments <- [
          ["--", "test/second_test.exs"],
          ["--no-dry-run", "--", "test/second_test.exs"]
        ] do
      snapshot = capture!(root, arguments)
      assert snapshot.modules[CaptureFixture.SecondTest]
      assert snapshot.modules[CaptureFixture.Helper]
      refute snapshot.modules[CaptureFixture.FirstTest]
      refute File.exists?(Path.join(root, "body-ran"))
    end
  end

  test "failed compilation does not invoke analysis or retain a partial capture", %{tmp_dir: root} do
    fixture!(root)

    File.write!(
      Path.join(root, "test/broken_test.exs"),
      "defmodule Broken do\n this is broken syntax !!!\nend"
    )

    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        try do
          TestCapture.run(["--max-requires", "1"], fn _ ->
            File.write!("analysis-ran", "unexpected")
          end)

          flunk("the native test compilation should fail")
        catch
          :exit, {:shutdown, 1} -> :ok
        end

        refute File.exists?("analysis-ran")
        assert Path.wildcard(Path.join(Mix.Project.manifest_path(), "argus-test-capture-*")) == []
        refute Mix.Project.config()[:test_elixirc_options]
      end)
    end)
  end

  test "a reused test VM fails instead of silently omitting required helpers", %{tmp_dir: root} do
    fixture!(root)
    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        TestCapture.run([], fn _ -> :ok end)

        assert_raise Mix.Error, ~r/requires a fresh Mix VM; .* was already required/, fn ->
          TestCapture.run([], fn _ ->
            flunk("must not analyze an incomplete capture")
          end)
        end
      end)
    end)
  end

  test "retains the last complete BEAM when a helper recompiles a module", %{tmp_dir: root} do
    fixture!(root)

    File.write!(Path.join(root, "test/test_helper.exs"), ~S"""
    ExUnit.start()
    Code.compile_string("defmodule CaptureFixture.Recompiled do; def value, do: :first; end")
    Code.compile_string("defmodule CaptureFixture.Recompiled do; def value, do: :second; end")
    """)

    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        TestCapture.run([], fn project ->
          scan = Scan.scan(Argus.Config.load([]), project)
          beam = Map.fetch!(scan.modules, CaptureFixture.Recompiled)

          assert {:ok, {_, [{:abstract_code, {:raw_abstract_v1, forms}}]}} =
                   :beam_lib.chunks(String.to_charlist(beam), [:abstract_code])

          assert {:function, _, :value, 0, [{:clause, _, [], [], [{:atom, _, :second}]}]} =
                   Enum.find(forms, &match?({:function, _, :value, 0, _}, &1))
        end)
      end)
    end)
  end

  test "captured redefinition takes precedence over the application BEAM", %{tmp_dir: root} do
    fixture!(root)

    File.write!(Path.join(root, "test/test_helper.exs"), ~S"""
    ExUnit.start()
    Code.compile_string("defmodule CaptureFixture.Support do; def value, do: :redefined; end")
    """)

    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        TestCapture.run([], fn project ->
          scan = Scan.scan(Argus.Config.load([]), project)
          beam = Map.fetch!(scan.modules, CaptureFixture.Support)
          {_, directory} = List.first(project.apps)
          assert Path.dirname(beam) == directory

          assert {:ok, {_, [{:abstract_code, {:raw_abstract_v1, forms}}]}} =
                   :beam_lib.chunks(String.to_charlist(beam), [:abstract_code])

          assert {:function, _, :value, 0, [{:clause, _, [], [], [{:atom, _, :redefined}]}]} =
                   Enum.find(forms, &match?({:function, _, :value, 0, _}, &1))
        end)
      end)
    end)
  end

  test "analysis failure restores compiler options and removes the capture", %{tmp_dir: root} do
    fixture!(root)
    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        original = Code.compiler_options()
        test_options = [debug_info: false]
        Mix.ProjectStack.merge_config(test_elixirc_options: test_options)

        assert_raise RuntimeError, "analysis failed", fn ->
          TestCapture.run([], fn project ->
            {_, directory} = List.first(project.apps)
            assert File.exists?(Path.join(directory, "Elixir.CaptureFixture.FirstTest.beam"))
            raise "analysis failed"
          end)
        end

        assert Code.compiler_options() == original
        assert Mix.Project.config()[:test_elixirc_options] == test_options
        assert Path.wildcard(Path.join(Mix.Project.manifest_path(), "argus-test-capture-*")) == []
      end)
    end)
  end

  test "preserves global and test-specific compiler tracers", %{tmp_dir: root} do
    fixture!(root)

    File.write!(Path.join(root, "lib/tracer.ex"), """
    defmodule CaptureFixture.TestTracer do
      def trace({:on_module, _, _}, %{module: CaptureFixture.FirstTest}) do
        File.write!("test-tracer-fired", "yes")
        :ok
      end
      def trace(_, _), do: :ok
    end
    """)

    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        Code.compiler_options(tracers: [__MODULE__])
        original = Code.compiler_options()
        test_options = [tracers: [CaptureFixture.TestTracer], debug_info: false]
        Mix.ProjectStack.merge_config(test_elixirc_options: test_options)

        TestCapture.run([], fn _ ->
          assert File.read!("global-tracer-fired") == "yes"
          assert File.read!("test-tracer-fired") == "yes"
        end)

        assert Code.compiler_options() == original
        assert Mix.Project.config()[:test_elixirc_options] == test_options
      end)
    end)
  end

  @doc false
  @spec trace(event :: term(), environment :: Macro.Env.t()) :: :ok
  def trace({:on_module, _, _}, %{module: CaptureFixture.FirstTest}) do
    File.write!("global-tracer-fired", "yes")
    :ok
  end

  def trace(_, _), do: :ok

  test "native --no-compile keeps the existing application build", %{tmp_dir: root} do
    fixture!(root)
    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        MixProject.compile!()
        File.write!("lib/support.ex", "defmodule BrokenApplication do this is not valid !!! end")
        Mix.Task.clear()

        TestCapture.run(["--no-compile"], fn project ->
          scan = Scan.scan(Argus.Config.load([]), project)
          assert scan.modules[CaptureFixture.Support]
          assert scan.modules[CaptureFixture.FirstTest]
        end)
      end)
    end)
  end

  @tag :flowlog
  test "the public task reports native findings and applies the warning gate", %{tmp_dir: root} do
    fixture!(root)

    File.write!(Path.join(root, "test/first_test.exs"), """
    IO.warn("intentional test compilation warning")
    defmodule CaptureFixture.ManualDirectoryTest do
      use ExUnit.Case
      setup_all do
        directory = Path.join(System.tmp_dir!(), "manual_exunit_directory")
        File.mkdir_p!(directory)
        :ok
      end
      test "body", do: :ok
    end
    """)

    File.write!(
      Path.join(root, "test/test_helper.exs"),
      ~s|IO.puts("test helper output remains visible")\n|,
      [:append]
    )

    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        Mix.ProjectStack.merge_config(argus: [analyses: [:exunit_tmp_dir]])

        {{_result, output}, stdout} =
          with_io(fn ->
            with_io(:stderr, fn ->
              assert_raise Mix.Error, ~r/findings at --fail-on warning or above/, fn ->
                Test.run(["--fail-on", "warning"])
              end
            end)
          end)

        assert output =~ "argus.test: compiling project and capturing test BEAMs"
        assert output =~ "argus.test: analyzing captured BEAMs"
        assert output =~ "intentional test compilation warning"
        assert stdout =~ "test helper output remains visible"
        refute stdout =~ "Running ExUnit"
        refute stdout =~ "Tests that would be executed:"
        refute stdout =~ "Result:"
        refute stdout =~ "test body"
        assert output =~ "warning[argus.exunit_tmp_dir]"
        assert output =~ "test/first_test.exs"
        assert output =~ "setup_all runs before per-test directories exist"
        assert Path.wildcard(Path.join(Mix.Project.manifest_path(), "argus-test-capture-*")) == []
      end)
    end)
  end

  test "the public task preserves native compilation errors", %{tmp_dir: root} do
    fixture!(root)
    File.write!(Path.join(root, "test/broken_test.exs"), "defmodule Broken do def invalid( end")
    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        {{_result, stderr}, stdout} =
          with_io(fn ->
            with_io(:stderr, fn ->
              assert catch_exit(Test.run([])) == {:shutdown, 1}
            end)
          end)

        assert stderr =~ "argus.test: compiling project and capturing test BEAMs"
        refute stderr =~ "argus.test: analyzing captured BEAMs"
        assert stdout <> stderr =~ "Compilation error in file"
        assert stdout <> stderr =~ "test/broken_test.exs"
      end)
    end)
  end

  test "an explicit native formatter keeps the requested dry-run output", %{tmp_dir: root} do
    fixture!(root)
    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        output =
          capture_io(fn ->
            TestCapture.run(["--formatter", "ExUnit.CLIFormatter"], fn _ -> :ok end)
          end)

        assert output =~ "Running ExUnit"
        assert output =~ "Tests that would be executed:"
      end)
    end)
  end

  test "capture limits native test compilation and honors explicit concurrency", %{tmp_dir: root} do
    for {arguments, expected} <- [
          {[], 1},
          {["--max-requires", "2"], 2},
          {["--max-requires=2"], 2}
        ] do
      fixture!(root)

      File.write!(Path.join(root, "lib/concurrency_tracer.ex"), ~S"""
      defmodule CaptureFixture.ConcurrencyTracer do
        def trace(event, %{file: file, lexical_tracker: lexical}) when event in [:start, :stop] do
          if String.ends_with?(file, "_test.exs") do
            compiler = self()

            expected = Agent.get_and_update(CaptureFixture.CompilationTracker, fn state ->
              active = if event == :start, do: Map.put(state.active, lexical, compiler), else: Map.delete(state.active, lexical)
              maximum = max(state.maximum, map_size(active))
              starts = state.starts + if(event == :start, do: 1, else: 0)

              if event == :start and state.expected == 2 and map_size(active) == 2 do
                Enum.each(Map.values(active), &send(&1, :compilers_ready))
              end

              {state.expected, %{state | active: active, maximum: maximum, starts: starts}}
            end)

            if event == :start and expected == 2 do
              receive do
                :compilers_ready -> :ok
              after
                10_000 -> raise "native compilation did not admit the requested second compiler"
              end
            end
          end

          :ok
        end

        def trace(_, _), do: :ok
      end
      """)

      File.write!(Path.join(root, "test/test_helper.exs"), """
      ExUnit.start()
      {:ok, _} = Agent.start_link(fn -> %{expected: #{expected}, active: %{}, maximum: 0, starts: 0} end,
        name: CaptureFixture.CompilationTracker)
      """)

      peer = Peer.start!()

      Peer.run(peer, fn ->
        Mix.Project.in_project(:capture_fixture, root, fn _ ->
          Mix.ProjectStack.merge_config(
            test_elixirc_options: [tracers: [CaptureFixture.ConcurrencyTracer]]
          )

          TestCapture.run(arguments, fn _ ->
            state = Agent.get(CaptureFixture.CompilationTracker, & &1)
            assert state.maximum == expected
            assert state.starts == 2
            assert state.active == %{}
          end)
        end)
      end)
    end
  end

  @tag :flowlog
  test "the public task fails when native reporting marks an analysis degraded", %{tmp_dir: root} do
    fixture!(root)
    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        MixProject.compile!()
        Mix.ProjectStack.merge_config(argus: [analyses: [{MissingExternalAnalysis, []}]])

        {{_result, stderr}, stdout} =
          with_io(fn ->
            with_io(:stderr, fn ->
              assert_raise Mix.Error,
                           "argus: analysis did not complete; see the diagnostics above",
                           fn ->
                             Test.run(["--format", "json"])
                           end
            end)
          end)

        assert JSON.decode!(stdout) == []
        assert stderr =~ "the missing_external analysis degraded and reported nothing"
        assert stderr =~ "unavailable.dl"
      end)
    end)
  end

  defp capture!(root, args) do
    peer = Peer.start!()

    Peer.run(peer, fn ->
      Mix.Project.in_project(:capture_fixture, root, fn _ ->
        original = Code.compiler_options()

        snapshot =
          TestCapture.run(args, fn project ->
            scan = Scan.scan(Argus.Config.load([]), project)

            path =
              Enum.find_value(
                [CaptureFixture.FirstTest, CaptureFixture.SecondTest, CaptureFixture.RenamedTest],
                &Map.get(scan.modules, &1)
              )

            {:ok, {_, chunks}} =
              :beam_lib.chunks(String.to_charlist(path), [:debug_info, :compile_info])

            helper = Map.fetch!(scan.modules, CaptureFixture.Helper)

            {:ok, {_, [debug_info: helper_debug_info]}} =
              :beam_lib.chunks(String.to_charlist(helper), [:debug_info])

            {_, directory} = List.first(project.apps)

            %{
              modules: scan.modules,
              directory: directory,
              initialized: File.exists?("helper-initialized"),
              helper_debug_info: match?({:debug_info_v1, _, _}, helper_debug_info),
              debug_info: match?({:debug_info_v1, _, _}, chunks[:debug_info]),
              source: to_string(chunks[:compile_info][:source])
            }
          end)

        assert Code.compiler_options() == original
        snapshot
      end)
    end)
  end

  defp fixture!(root) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule CaptureFixture.MixProject do
      use Mix.Project
      def project, do: [app: :capture_fixture, version: "0.1.0", deps: []]
    end
    """)

    File.write!(
      Path.join(root, "lib/support.ex"),
      "defmodule CaptureFixture.Support do\n def value, do: :support\nend"
    )

    File.write!(Path.join(root, "test/test_helper.exs"), """
    ExUnit.start()
    File.write!("helper-initialized", "yes")
    defmodule CaptureFixture.Helper do
      def value, do: :helper
    end
    """)

    File.write!(Path.join(root, "test/first_test.exs"), test_source(CaptureFixture.FirstTest))
    File.write!(Path.join(root, "test/second_test.exs"), test_source(CaptureFixture.SecondTest))
  end

  defp test_source(module) do
    """
    defmodule #{inspect(module)} do
      use ExUnit.Case
      setup_all do
        File.write!("body-ran", "setup_all")
        :ok
      end
      setup do
        File.write!("body-ran", "setup")
        :ok
      end
      test "body" do
        File.write!("body-ran", "test")
        :ok
      end
    end
    """
  end
end
