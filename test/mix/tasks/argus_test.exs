defmodule Mix.Tasks.ArgusTest do
  @moduledoc """
  The standalone one-shot task, driven inside the fixture project. The
  compiler runs first (via the full chain), so the standalone runs
  exercise the shared-manifest warm path. In this module's peer
  (`Argus.Test.Peer`): the Mix project stack, the working directory and
  telemetry are VM-wide.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  import ExUnit.CaptureIO

  alias Argus.Test.{Fixture, Peer, ReviewedFrontend}
  alias Mix.Tasks.Compile.Argus, as: ArgusCompiler
  alias Roux.QueryLog

  @moduletag timeout: 300_000
  @moduletag :flowlog

  # The two analyses with findings on the fixture (the five the reports
  # count); `--list` marks the default set whatever the config says.
  @quick [analyses: [:coupling, :mailbox]]

  # One checkout, compiled once: every test here reads the warm manifest
  # and none edits the fixture, so the cold compile is paid per module,
  # not per test. The `compile!()` each test opens with is then a no-op.
  setup_all do
    peer = Peer.start!()
    copy = Fixture.checkout!(Path.join(System.tmp_dir!(), "argus_task_depot"), @quick)
    Fixture.in_peer(peer, copy, :depot, fn _log -> compile!() end)
    %{copy: copy, peer: peer}
  end

  defp in_project(%{peer: peer, copy: copy}, fun), do: Fixture.in_peer(peer, copy, :depot, fun)

  defp compile!, do: Fixture.compile!()

  test "runs warm off the compiler's manifest and reports", context do
    in_project(context, fn log ->
      compile!()

      # The standalone task shares the compiler's manifest: nothing
      # re-extracts, nothing re-solves.
      QueryLog.reset(log)

      output =
        capture_io(:stderr, fn ->
          Mix.Task.rerun("argus", [])
        end)

      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :solve) == []

      assert output =~ "warning[argus.coupling]"
      assert output =~ "warning[argus.mailbox]"
      assert output =~ "3 findings (2 warnings, 1 info)"
    end)
  end

  test "reports each finding once, though the compile it runs has the :argus compiler",
       context do
    in_project(context, fn _log ->
      compile!()

      # As a fresh `mix argus` does, the compile chain runs again.
      Mix.Task.clear()

      output = capture_io(:stderr, fn -> Mix.Task.run("argus", []) end)

      assert [_] = Regex.scan(~r/warning\[argus\.coupling\]/, output)
      assert output =~ "3 findings (2 warnings, 1 info)"
    end)
  end

  test "--format json emits the stable schema", context do
    in_project(context, fn _log ->
      compile!()

      json =
        capture_io(fn ->
          Mix.Task.rerun("argus", ["--format", "json"])
        end)

      entries = JSON.decode!(json)
      assert length(entries) == 3

      assert [first] = Enum.filter(entries, &(&1["analysis"] == "coupling"))
      assert first["severity"] == "warning"
      assert first["file"] == "lib/depot/application.ex"
      assert is_integer(first["line"])
      assert first["title"] == "Coupled children under one_for_one"
      assert first["at_label"] == "supervision tree defined here"
      assert is_binary(first["detail"])
      assert first["provenance"] == "structural"
      assert Map.has_key?(first, "confidence") and is_nil(first["confidence"])
      assert Map.has_key?(first, "end_line")
      assert [help | _] = first["help"]
      assert help =~ "rest_for_one"

      # Sonar's listen from handle_continue/2, and the Notifier clause
      # that keeps it.
      assert Enum.any?(first["related"], fn related ->
               related["label"] == "registers with the sibling here" and
                 is_integer(related["line"]) and related["file"] == "lib/depot/sonar.ex"
             end)

      assert Enum.any?(first["related"], fn related ->
               related["label"] == "kept here" and is_integer(related["line"]) and
                 related["file"] == "lib/depot/notifier.ex"
             end)
    end)
  end

  test "--fail-on raises on a finding at the severity or above", context do
    in_project(context, fn _log ->
      compile!()

      assert_raise Mix.Error, ~r/findings at --fail-on info or above/, fn ->
        capture_io(:stderr, fn -> Mix.Task.rerun("argus", ["--fail-on", "info"]) end)
      end

      capture_io(:stderr, fn ->
        assert Mix.Task.rerun("argus", ["--fail-on", "error"]) != :failed
      end)
    end)
  end

  test "--fail-above raises when the count is exceeded", context do
    in_project(context, fn _log ->
      compile!()

      assert_raise Mix.Error, ~r/3 findings exceed --fail-above 0/, fn ->
        capture_io(:stderr, fn -> Mix.Task.rerun("argus", ["--fail-above", "0"]) end)
      end

      # At or below the threshold passes.
      capture_io(:stderr, fn ->
        assert Mix.Task.rerun("argus", ["--fail-above", "3"]) != :failed
      end)
    end)
  end

  test "positional analyses narrow the run; unknown names abort", context do
    in_project(context, fn _log ->
      compile!()

      output =
        capture_io(:stderr, fn ->
          Mix.Task.rerun("argus", ["mailbox"])
        end)

      assert output =~ "warning[argus.mailbox]"
      refute output =~ "argus.coupling"
      assert output =~ "2 findings (1 warning, 1 info)"

      assert_raise Argus.ConfigError, ~r/unknown analyses \[:nonsense\]/, fn ->
        capture_io(:stderr, fn -> Mix.Task.rerun("argus", ["nonsense"]) end)
      end
    end)
  end

  test "--list names every analysis and marks the default set", context do
    in_project(context, fn _log ->
      output = capture_io(fn -> Mix.Task.rerun("argus", ["--list"]) end)

      assert output =~ "* coupling"
      assert output =~ "* mailbox"
      assert output =~ "  unsafe_input"
      assert output =~ "security: unsafe_input exposure"
      refute output =~ "coverage"
    end)
  end

  describe "the compile it runs first" do
    # Own checkouts with their own app atoms: in_project caches project
    # config by app name, and these need an argus: config of their own.
    test "a finding that fails the compiler's fail_on is reported, not fatal", %{peer: peer} do
      app = :depot_task_error

      copy =
        Fixture.checkout!(
          Path.join(System.tmp_dir!(), "argus_#{app}"),
          [severity: [mailbox: :error]] ++ @quick,
          app
        )

      Fixture.in_peer(peer, copy, app, fn _log ->
        # mix compile fails here: the mailbox findings are errors and
        # fail_on is :error. Built once so stdout carries only the JSON;
        # cleared so the task's own compile runs (warm) and sees :error.
        assert {:error, _diagnostics} = compile!()
        Mix.Task.clear()

        {json, _stderr} =
          with_io(:stderr, fn ->
            capture_io(fn -> Mix.Task.rerun("argus", ["--format", "json"]) end)
          end)

        entries = JSON.decode!(json)
        assert length(entries) == 3

        mailbox = Enum.filter(entries, &(&1["analysis"] == "mailbox"))
        assert length(mailbox) == 2
        assert Enum.all?(mailbox, &(&1["severity"] == "error"))
      end)
    end

    test "a project that does not compile is an error, with no report", %{peer: peer} do
      app = :depot_task_broken
      copy = Fixture.checkout!(Path.join(System.tmp_dir!(), "argus_#{app}"), @quick, app)

      File.write!(
        Path.join(copy, "lib/depot/broken.ex"),
        "defmodule Depot.Broken do\n  def f(, do: :ok\nend\n"
      )

      Fixture.in_peer(peer, copy, app, fn _log ->
        Mix.Task.clear()

        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/does not compile/, fn ->
            capture_io(fn -> Mix.Task.rerun("argus", ["--format", "json"]) end)
          end
        end)
      end)
    end
  end

  test "exact review JSON preserves visible findings through cold and warm task gates", %{
    peer: peer
  } do
    {copy, app} = ReviewedFrontend.checkout!()

    Fixture.in_peer(peer, copy, app, fn _log ->
      ReviewedFrontend.bootstrap!()
      ReviewedFrontend.assert_reviewed!(:task)
      ReviewedFrontend.assert_reviewed!(:task)
    end)
  end

  test "missing, malformed and duplicate review records fail the real task", %{peer: peer} do
    {copy, app} = ReviewedFrontend.checkout!()

    Fixture.in_peer(peer, copy, app, fn _log ->
      {_run, [first | _] = records} = ReviewedFrontend.bootstrap!()
      ReviewedFrontend.assert_reviewed!(:task)

      for bytes <- ["[", "{}", JSON.encode!([first, first]), "[{\"version\":1,\"version\":1}]"] do
        File.write!("reviews.json", bytes)
        assert_raise Argus.ConfigError, fn -> ReviewedFrontend.invoke(:task) end
      end

      File.rm!("reviews.json")
      assert ArgusCompiler.diagnostics() == []
      assert_raise Argus.ConfigError, fn -> ReviewedFrontend.invoke(:task) end
      ReviewedFrontend.write_records(records)
      ReviewedFrontend.assert_reviewed!(:task)
    end)
  end

  test "raw source changes invalidate an exact review in the real task", %{peer: peer} do
    {copy, app} = ReviewedFrontend.checkout!()

    Fixture.in_peer(peer, copy, app, fn _log ->
      ReviewedFrontend.bootstrap!()
      ReviewedFrontend.assert_reviewed!(:task)

      ReviewedFrontend.edit!(
        "lib/depot/review_caller_5.ex",
        &("# changed raw source\n" <> &1)
      )

      assert ArgusCompiler.diagnostics() == []

      assert_raise ArgumentError, ~r/stale review/, fn ->
        ReviewedFrontend.invoke(:task)
      end
    end)
  end

  test "a nonrepresentative witness changes the full census at unchanged primary count in task",
       %{peer: peer} do
    {copy, app} = ReviewedFrontend.checkout!()

    Fixture.in_peer(peer, copy, app, fn _log ->
      {original, records} = ReviewedFrontend.bootstrap!()

      ReviewedFrontend.edit!(
        "lib/depot/review_caller_5.ex",
        &String.replace(&1, "def ask", "def changed_witness")
      )

      changed = ReviewedFrontend.changed!()

      before =
        Enum.find(
          original.review.analyses.blocking.findings,
          &(&1.title == "High synchronous fan-in")
        )

      after_finding =
        Enum.find(
          changed.review.analyses.blocking.findings,
          &(&1.title == "High synchronous fan-in")
        )

      assert before.review_identity.row == after_finding.review_identity.row

      refute before.review_identity.census.outputs["bottleneck_caller"] ==
               after_finding.review_identity.census.outputs["bottleneck_caller"]

      ReviewedFrontend.write_records(records)

      assert_raise ArgumentError, ~r/stale review/, fn ->
        ReviewedFrontend.invoke(:task)
      end
    end)
  end

  test "a new self-call in the same reviewed MFA fails the actual task gate", %{peer: peer} do
    {copy, app} = ReviewedFrontend.checkout!()

    Fixture.in_peer(peer, copy, app, fn _log ->
      {original, old_records} = ReviewedFrontend.bootstrap!()

      ReviewedFrontend.edit!(
        "lib/depot/sonar.ex",
        &String.replace(
          &1,
          "def handle_call(:ping, _from, state) do",
          "def handle_call(:ping, _from, state) do\n    GenServer.call(self(), :ping)"
        )
      )

      changed = ReviewedFrontend.changed!()

      previous =
        Enum.find(
          original.review.analyses.blocking.findings,
          &(&1.title == "High synchronous fan-in")
        )

      defect =
        Enum.find(
          changed.review.analyses.blocking.findings,
          &(&1.title == "Synchronous call to the calling process itself")
        )

      assert defect.mfa == previous.mfa
      assert defect.severity == :error
      ReviewedFrontend.write_records(old_records)

      assert_raise ArgumentError, ~r/stale review/, fn ->
        ReviewedFrontend.invoke(:task)
      end

      ReviewedFrontend.write_records(ReviewedFrontend.records(changed, defect.title))

      ReviewedFrontend.assert_new_error!(:task)
    end)
  end

  test "duplicate real input beams cannot provide complete review proof for task", %{peer: peer} do
    {copy, app} = ReviewedFrontend.checkout!()

    Fixture.in_peer(peer, copy, app, fn _log ->
      ReviewedFrontend.bootstrap!()
      source = Path.join(Mix.Project.compile_path(), "Elixir.Depot.Sonar.beam")
      duplicate = Path.join([Mix.Project.build_path(), "lib", "review_duplicate", "ebin"])
      File.mkdir_p!(duplicate)
      File.cp!(source, Path.join(duplicate, "Elixir.Depot.Sonar.beam"))

      assert_raise ArgumentError, ~r/duplicate input modules/, fn ->
        ReviewedFrontend.invoke(:task)
      end
    end)
  end
end
