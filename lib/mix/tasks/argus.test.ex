defmodule Mix.Tasks.Argus.Test do
  @shortdoc "Compiles tests without running their bodies and analyzes their BEAMs"

  @moduledoc """
  Captures test BEAMs through `mix test --dry-run`, then runs the normal Argus
  Driver and report pipeline over the project and the captured modules.

      mix argus.test
      mix argus.test --format json -- test/example_test.exs
      mix argus.test --fail-on warning -- --max-requires 1

  Argus options precede `--`; native `mix test` options and paths follow it.
  Without paths, Mix selects the configured test paths and patterns. Each run
  captures only that invocation's compiled test and helper modules. It never
  reuses a previous capture, including after compilation fails or files change.
  Deleted files and files omitted by a partial selection are not analyzed.
  Every function in a compiled module is analyzed, even if line, tag, or name
  filters would prevent ExUnit from running some tests in that module.

  Test bodies, `setup`, and `setup_all` callbacks do not run. The application
  starts normally and `test_helper.exs` and other top-level compilation code
  execute. This is not a sandbox for untrusted code. Ordinary Mix compilation
  and dry-run output can precede the Argus report, including JSON reports.

  Requires Elixir 1.19 or later. The task defaults to `MIX_ENV=test` and retains
  test debug information for analysis. Native test diagnostics fail the command;
  no captured modules are analyzed after compilation fails. The capture is
  removed after the command. Its native Argus manifest is separate from the
  ordinary application scan. Run this task in a fresh Mix VM. If a file under
  the configured test paths was already required, the task fails instead of
  silently omitting cached helper modules.
  """

  use Mix.Task

  alias Argus.CLI.Options

  @preferred_cli_env :test
  @recursive true

  @impl Mix.Task
  def run(args) do
    {argus_args, test_args} = Enum.split_while(args, &(&1 != "--"))
    test_args = Enum.drop(test_args, 1)

    options =
      case Options.parse(argus_args, :mix) do
        {:ok, options} -> options
        {:error, message} -> Mix.raise("argus.test: " <> message)
      end

    case options.command do
      :help ->
        Mix.shell().info(@moduledoc)

      :list ->
        IO.write(Argus.CLI.list())

      :analyze ->
        {:ok, _apps} = Application.ensure_all_started(:telemetry)
        if options.offline, do: Argus.Offline.enable()

        Argus.Mix.TestCapture.run(test_args, fn project ->
          Mix.Tasks.Argus.analyze(options, project: project)
        end)
    end
  end
end
