defmodule Argus.Analyses.ExUnitTmpDirScaleTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  @tag :tmp_dir
  test "callback eligibility and execution reach stay demand-bounded", %{tmp_dir: tmp_dir} do
    cases = for n <- 1..120, do: "Case#{n}"
    helpers = for n <- 1..240, do: ["Helpers:unused#{n}/1", "Helpers", "unused#{n}", "1", "1"]
    product = for n <- 1..240, do: ["Product:step#{n}/0", "Product", "step#{n}", "0", "1"]

    definitions =
      Enum.flat_map(cases, fn mod ->
        [
          ["#{mod}:__ex_unit__/0", mod, "__ex_unit__", "0", "1"],
          ["#{mod}:test irrelevant/1", mod, "test irrelevant", "1", "1"]
        ]
      end) ++
        helpers ++
        product ++
        [
          ["Case1:__ex_unit__/2", "Case1", "__ex_unit__", "2", "1"],
          ["Helpers:setup/1", "Helpers", "setup", "1", "1"],
          ["Factory:root/0", "Factory", "root", "0", "1"]
        ]

    calls =
      Enum.map(cases, fn mod ->
        ["#{mod}:test irrelevant/1#1", "#{mod}:test irrelevant/1", "Product", "step1", "0"]
      end) ++
        for n <- 1..239 do
          ["Product:step#{n}/0#1", "Product:step#{n}/0", "Product", "step#{n + 1}", "0"]
        end ++
        [
          ["Case1:__ex_unit__/2#1", "Case1:__ex_unit__/2", "Helpers", "setup", "1"],
          ["Helpers:setup/1#1", "Helpers:setup/1", "Factory", "root", "0"],
          ["Helpers:setup/1#2", "Helpers:setup/1", "File", "mkdir_p!", "1"],
          ["Helpers:setup/1#3", "Helpers:setup/1", "Product", "step1", "0"]
        ]

    facts = %{
      function_def: definitions,
      remote_call: calls,
      tooling_module: [["Helpers", "test_support"]],
      clause_call: [["Case1:__ex_unit__/2#1", "Case1:__ex_unit__/2", ":setup_all"]],
      tmp_dir_return: [["Factory:root/0", "root", "Factory:root/0#1"]],
      tmp_dir_argument: [
        [
          "Helpers:setup/1#2",
          "Helpers:setup/1",
          "File:mkdir_p!/1",
          "0",
          "call",
          "Helpers:setup/1#1"
        ]
      ]
    }

    facts_dir = Path.join(tmp_dir, "facts")
    File.mkdir_p!(facts_dir)
    empty = Map.new(Argus.Schema.names(), &{&1, []})
    :ok = Argus.Pipeline.write_facts(Map.merge(empty, facts), facts_dir)
    program = Path.join(tmp_dir, "bounded.dl")
    rules = Argus.Dl.path("analyses/exunit_tmp_dir.dl")

    File.write!(program, """
    .include #{inspect(rules)}
    .output tmp_callback
    .output tmp_reach
    .limitsize tmp_callback(n=2)
    .limitsize tmp_reach(n=3)
    """)

    assert {:ok, result} = Argus.Analysis.run_rules(facts_dir, {:custom, program})
    assert result["tmp_callback"] == [["Helpers:setup/1", "Case1"]]
    assert result["tmp_reach"] == [["Helpers:setup/1", "setup_all", "Helpers:setup/1"]]

    assert result["exunit_manual_tmp_dir"] == [
             [
               "Helpers:setup/1",
               "setup_all",
               "Helpers:setup/1",
               "Helpers:setup/1#2",
               "Factory:root/0#1"
             ]
           ]
  end
end
