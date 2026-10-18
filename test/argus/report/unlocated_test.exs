defmodule Argus.Report.UnlocatedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Argus.Report
  alias Argus.Test.ReportShapes

  setup do
    %{
      cwd: ReportShapes.root(),
      unlocated: ReportShapes.unlocated(),
      config: Argus.Config.load(analyses: [:coupling])
    }
  end

  test "only intentionally unanchored findings survive a missing location", context do
    %{unlocated: unlocated, config: config, cwd: cwd} = context

    outside =
      for anchor <- [
            Argus.Findings.at_module("Shapes.Outside"),
            Argus.Findings.at_mfa("Shapes.Outside", :run, 0),
            Argus.Findings.at_instr("Shapes.Outside:run/0#1")
          ] do
        assert Enum.any?([anchor.module, anchor.mfa, anchor.instr], &(&1 != nil))
        %{unlocated | finding: Map.merge(unlocated.finding, anchor)}
      end

    assert [%{file: nil, line: nil, end_line: nil}] =
             Report.build(%{coupling: {:ok, outside ++ [unlocated]}}, config, cwd)
  end

  test "file and unrelated module ignores do not suppress unlocated findings", context do
    config =
      Argus.Config.load(
        analyses: [:coupling],
        ignore: [files: ["**"], findings: [{:coupling, Shapes.Outside}]],
        severity: [coupling: :error]
      )

    assert [%{file: nil, severity: :error}] =
             Report.build(%{coupling: {:ok, [context.unlocated]}}, config, context.cwd)
  end

  test "JSON preserves null locations and the existing schema order", context do
    entries = entries(context)
    json = Report.Json.encode(entries, context.cwd)
    ReportShapes.assert_key_order!(json)

    assert [
             %{
               "file" => nil,
               "line" => nil,
               "end_line" => nil,
               "related" => [],
               "severity" => "warning",
               "title" => "A finding without a code anchor",
               "help" => ["Review the analysis inputs."]
             }
           ] = JSON.decode!(json)
  end

  test "text and compiler diagnostics use Pentiment without a source label", context do
    [entry] = entries(context)
    {report, sources} = Report.Pentiment.report(entry, context.cwd)
    assert report.source == nil
    assert report.labels == []
    assert sources == %{}

    text = Report.Text.format([entry], [], context.cwd, color: :never)
    assert text =~ "warning[argus.coupling]: A finding without a code anchor"
    assert text =~ "A finding without a code anchor: the detail."
    assert text =~ "Review the analysis inputs."
    assert text =~ "1 finding (1 warning)"
    refute text =~ "mix.exs"
    refute text =~ "╭─["

    assert [%{diagnostic: diagnostic}] = Argus.Mix.Diagnostics.build([entry], context.cwd)
    assert diagnostic.file == nil
    assert diagnostic.source == nil
    assert diagnostic.position == 0
    assert diagnostic.severity == :warning
    assert diagnostic.message == "[argus.coupling] A finding without a code anchor"
    assert diagnostic.details == Report.Pentiment.format(entry, context.cwd, colors: false)
  end

  test "an unlocated finding preserves related source evidence without a primary anchor",
       context do
    {:ok, [anchored | _]} = ReportShapes.located().coupling

    unlocated = %{
      context.unlocated
      | finding: %{context.unlocated.finding | related: anchored.finding.related},
        related: anchored.related
    }

    [entry] = Report.build(%{coupling: {:ok, [unlocated]}}, context.config, context.cwd)

    assert Enum.map(entry.related, & &1.label) ==
             ["the same call", "kept here", "registers with the sibling here"]

    {report, sources} = Report.Pentiment.report(entry, context.cwd)
    assert report.source == nil
    assert length(report.labels) == 3
    assert Enum.sort(Map.keys(sources)) == ["src/other.ex", "src/shapes.ex"]
    text = Report.Pentiment.format(entry, context.cwd, colors: false)
    assert text =~ "the same call"
    assert text =~ "registers with the sibling here"
  end

  test "CLI count and severity gates include unlocated findings", context do
    assert %{status: 1, entries: [%{file: nil}]} = cli(context, fail_above: 0)
    assert %{status: 0} = cli(context, fail_above: 1)
    assert %{status: 0} = cli(context, fail_on: :error)
    assert %{status: 1} = cli(context, fail_on: :warning)

    config = Argus.Config.load(analyses: [:coupling], severity: [coupling: :error])

    assert %{status: 1, entries: [%{severity: :error}]} =
             cli(%{context | config: config}, fail_on: :error)
  end

  defp entries(context) do
    Report.build(%{coupling: {:ok, [context.unlocated]}}, context.config, context.cwd)
  end

  defp cli(context, options) do
    result = %Argus.Driver.Result{
      located: %{coupling: {:ok, [context.unlocated]}},
      notices: [],
      changed?: false
    }

    output =
      capture_io(fn ->
        report =
          Argus.CLI.report(
            result,
            [],
            context.config,
            struct!(Argus.CLI.Options, [format: :json] ++ options),
            context.cwd,
            context.cwd
          )

        send(self(), {:report, report})
      end)

    assert [%{"file" => nil}] = JSON.decode!(output)
    assert_receive {:report, report}
    report
  end
end
