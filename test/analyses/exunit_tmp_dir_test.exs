defmodule Argus.Analyses.ExUnitTmpDirTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Analyses.ExUnitTmpDir
  alias Argus.Test.Fixtures.ExUnitTmpDir, as: Fixture
  alias Argus.Test.Memo

  setup_all do
    {:ok, result} = Memo.analyze([Fixture, Fixture.Helpers, Fixture.Product], :exunit_tmp_dir)
    %{rows: result["exunit_manual_tmp_dir"], result: result}
  end

  test "reports a root made inside a test", %{rows: rows} do
    assert Enum.any?(rows, fn [entry, phase | _] ->
             entry =~ ":test manual root/1" and phase == "test"
           end)
  end

  test "follows a returned root and forwarded parameters through another module", %{rows: rows} do
    assert Enum.any?(rows, fn [entry, phase, func, _, root] ->
             entry =~ "test manual root through helpers" and phase == "test" and
               func =~ ".Helpers:create/1" and root =~ ".Helpers:root/0#"
           end)
  end

  test "does not mix a manual caller with an independent safe caller", %{rows: rows} do
    for name <- [
          "child beneath",
          "unrelated temporary-directory read",
          "constant directory",
          "two calls to the same",
          "discard its manual-root",
          "absolute path ignores",
          "application code exercised",
          "Erlang absname ignores",
          "Erlang join ignores",
          "Erlang list join",
          "unrelated manual root in a map",
          "unrelated manual root in a tuple"
        ] do
      refute Enum.any?(rows, fn [entry | _] -> entry =~ name end), name
    end
  end

  test "distinguishes per-test setup, inline setup_all and named setup_all", %{rows: rows} do
    assert Enum.any?(rows, fn [_, phase, func | _] ->
             phase == "setup" and func =~ "__ex_unit_setup_"
           end)

    assert Enum.any?(rows, fn [_, phase, func | _] ->
             phase == "setup_all" and func =~ "__ex_unit_setup_all_"
           end)

    assert Enum.any?(rows, fn [_, phase, func | _] ->
             phase == "setup_all" and func =~ ":named_shared_setup/1"
           end)
  end

  test "ignores production behavior even when a test calls it", %{rows: rows} do
    refute Enum.any?(rows, fn [_, _, func | _] -> func =~ ".Product:run/0" end)
  end

  test "relative expand still derives a manual temporary directory", %{rows: rows} do
    assert Enum.any?(rows, fn [entry | _] -> entry =~ "relative expand retains" end)
  end

  test "relative Erlang path constructors still report manual roots", %{rows: rows} do
    matching = Enum.filter(rows, fn [entry | _] -> entry =~ "Erlang relative paths retain" end)
    assert length(matching) == 2
  end

  test "describe setup is not reported once for every generated wrapper", %{rows: rows} do
    nested = Enum.filter(rows, fn [_, _, func | _] -> func =~ ":nested_setup/1" end)
    assert length(nested) == 1
  end

  test "native Findings.build preserves warning severity and diagnostic labels", %{
    rows: rows,
    result: result
  } do
    row = Enum.find(rows, fn [entry | _] -> entry =~ ":test manual root/1" end)
    assert row != nil
    assert result["tooling"] != []

    assert [finding] =
             Argus.Findings.build(ExUnitTmpDir, %{
               "exunit_manual_tmp_dir" => [row],
               "tooling" => result["tooling"]
             })

    assert finding.severity == :warning
    assert finding.title == "ExUnit creates a manual temporary directory"
    assert finding.at_label == "manual temporary directory created here"
    assert finding.instr != nil
    assert [%{label: "OS temporary directory selected here", instr: root}] = finding.related
    assert root != nil
    refute Map.has_key?(finding, :floor)
  end

  @tag flowlog: false
  test "setup_all help does not claim that ExUnit supplies a shared tmp_dir" do
    finding =
      ExUnitTmpDir.finding(
        :exunit_manual_tmp_dir,
        [
          "Example:shared/1",
          "setup_all",
          "Example:shared/1",
          "Example:shared/1#4",
          "Example:shared/1#2"
        ]
      )

    assert finding.detail =~ "context.tmp_dir is not available"
    assert Enum.join(finding.help) =~ "Move this work to per-test setup"
    assert Enum.join(finding.help) =~ "on_exit cleanup"
  end
end
