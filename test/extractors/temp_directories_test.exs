defmodule Argus.Extractors.TempDirectoriesTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.TempDirectories
  alias Argus.Test.Fixtures.ExUnitTmpDir, as: Fixture

  test "invalid literal path lists do not crash provenance extraction" do
    for {module, name, path_pos} <- [
          {Path, :expand, 0},
          {:filename, :absname, 0},
          {:filename, :join, 1}
        ] do
      data = %{
        module: __MODULE__,
        functions: [
          {:function, :invalid_path, 0, 2,
           [
             {:label, 1},
             {:func_info, {:atom, __MODULE__}, {:atom, :invalid_path}, 0},
             {:label, 2},
             {:allocate, 1, 0},
             {:call_ext, 0, {:extfunc, System, :tmp_dir!, 0}},
             {:move, {:x, 0}, {:y, 0}},
             {:move, {:literal, [:invalid]}, {:x, path_pos}},
             {:move, {:y, 0}, {:x, 1 - path_pos}},
             {:call_ext, 2, {:extfunc, module, name, 2}},
             {:deallocate, 1},
             :return
           ]}
        ]
      }

      facts = TempDirectories.extract(data)

      assert Enum.any?(facts.tmp_dir_argument, fn
               [_site, _func, _callee, _pos, "root", _root] -> true
               _ -> false
             end)
    end
  end

  test "real compiled cases emit provenance without extraction errors" do
    assert {:ok, facts} =
             Argus.Pipeline.extract([Fixture, Fixture.Helpers, Fixture.Product],
               extractors: [TempDirectories],
               trace_imprecision: true
             )

    assert Map.get(facts, :extraction_error, []) == []
    assert Map.get(facts, :imprecision, []) == []

    assert Enum.any?(facts.tmp_dir_argument, fn
             [_site, func, "File:mkdir_p!/1", "0", "root", root] ->
               func =~ ":test manual root/1" and root =~ "#"

             _ ->
               false
           end)

    assert Enum.any?(facts.tmp_dir_return, fn
             [func, "root", _root] -> func =~ ".Helpers:root/0"
             _ -> false
           end)
  end
end
