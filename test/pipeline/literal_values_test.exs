defmodule Argus.Pipeline.LiteralValuesTest do
  use ExUnit.Case, async: true

  alias Argus.Pipeline.{Base, Disassemble, Emit}

  test "literal-only emission matches the complete emitter and restored disassembly" do
    for module <- [Enum, MapSet, Argus.Pipeline.Emit] do
      path = module |> :code.which() |> to_string()
      assert {:ok, data} = Disassemble.disassemble_path(path)
      expected = Map.take(Emit.emit(data), [:literal_value])
      assert expected != %{}
      assert Emit.literal_values(data) == expected

      typed =
        data |> Emit.emit() |> Map.take(Argus.Pipeline.typed_relations()) |> Argus.Facts.decode()

      cfg = Argus.Cfg.build(typed)
      reaching = Argus.Instr.Reaching.uses(data.module, data.functions)
      restored = Base.restore(Base.keep(data, typed, cfg, reaching), path)
      assert Emit.literal_values(restored.data) == expected
    end
  end

  test "literal-only emission keeps normalization, spelling and location stripping" do
    values = [
      {:integer, 7},
      {:atom, Example.Resource},
      {:literal, "tab\tline\nquote\""},
      {:float, 1.25},
      nil,
      {:literal, [file: "local.ex", line: 19, value: "kept"]},
      {:literal, %{file: "local.ex", line: 19, value: "kept"}}
    ]

    instructions = for value <- values, do: {:move, value, {:x, 0}}

    data = %{
      module: LiteralFixture,
      functions: [{:function, :run, 0, 1, instructions}],
      exports: []
    }

    assert Emit.literal_values(data) == Map.take(Emit.emit(data), [:literal_value])
    assert Emit.literal_values(%{module: EmptyFixture, functions: []}) == %{}
  end
end
