defmodule Argus.Analyses.ExUnitTmpDir do
  @moduledoc """
  Manual temporary-directory creation in ExUnit tests and callbacks.

  Follows temporary paths through selected helpers. Per-test callbacks can use
  ExUnit's `:tmp_dir` tag. `setup_all` has no per-test directory; its diagnostic
  recommends moving filesystem work to per-test setup or managing shared cleanup.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  @spec name() :: atom()
  def name, do: :exunit_tmp_dir

  @impl true
  @spec description() :: String.t()
  def description, do: "manual temporary directories in ExUnit tests and callbacks"

  @impl true
  @spec rules_file() :: String.t()
  def rules_file, do: "analyses/exunit_tmp_dir.dl"

  @impl true
  @spec extractors() :: [module()]
  def extractors,
    do: [Argus.Extractors.TempDirectories, Argus.Extractors.ClauseCall, Argus.Extractors.Tooling]

  @impl true
  @spec output_relations() :: [Argus.Analysis.output_relation()]
  def output_relations do
    [
      %{
        name: :exunit_manual_tmp_dir,
        fields: [
          {:entry, :symbol, "test or callback entry function"},
          {:phase, :symbol, "test | setup | setup_all"},
          {:func, :symbol, "directory-creating function"},
          {:site, :symbol, "directory creation call"},
          {:root, :symbol, "System temporary-directory call"}
        ],
        key: [:entry, :phase, :site],
        doc:
          "An ExUnit test or callback creates a directory derived from the OS temporary directory."
      },
      Findings.Tooling.relation()
    ]
  end

  @impl true
  @spec finding(relation :: atom(), row :: [String.t()]) :: Findings.attrs()
  def finding(:exunit_manual_tmp_dir, [entry, phase, func, site, root]) do
    Findings.new(
      :warning,
      "ExUnit creates a manual temporary directory",
      "#{entry} reaches #{func}, which creates a directory derived from System.tmp_dir/0 or System.tmp_dir!/0. " <>
        lifecycle_note(phase),
      at: Findings.at_site_in_func(site, func),
      at_label: "manual temporary directory created here",
      related: [Findings.related("OS temporary directory selected here", Findings.at_instr(root))],
      help: lifecycle_help(phase)
    )
    # This concern is specifically about test lifecycle. Test ownership is the
    # premise of the finding, so the native tooling step must not reduce it.
    |> Map.put(:floor, :warning)
  end

  defp lifecycle_note("setup_all"),
    do:
      "setup_all runs before per-test directories exist; context.tmp_dir is not available there."

  defp lifecycle_note(_phase),
    do: "ExUnit can provide an isolated per-test directory and own its lifecycle."

  defp lifecycle_help("setup_all"),
    do: [
      "Move this work to per-test setup with @tag tmp_dir: true and context.tmp_dir. If shared setup_all state is essential, create a unique directory and register explicit on_exit cleanup."
    ]

  defp lifecycle_help(_phase),
    do: [
      "Enable @tag tmp_dir: true for the test (or @moduletag tmp_dir: true), then use context.tmp_dir. Create child directories beneath that path when needed."
    ]
end
