defmodule Argus.Extractors.DecodedOriginTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.DecodedOrigin
  alias Argus.Pipeline.Disassemble

  test "float register writes do not prevent extraction of binary decode origins" do
    [{module, beam}] =
      Code.compile_string("""
      defmodule Argus.Test.FloatDecodeRegression do
        def untrusted(bytes, value) do
          scaled = value * 1.25
          {:erlang.binary_to_term(bytes), scaled}
        end

        def artifact(beam) do
          {:ok, {_module, [{~c"Attr", chunk}]}} = :beam_lib.chunks(beam, [~c"Attr"])
          :erlang.binary_to_term(chunk)
        end
      end
      """)

    assert {:ok, data} = Disassemble.disassemble_path(beam)

    assert Enum.any?(data.functions, fn {:function, _, _, _, instructions} ->
             Enum.any?(instructions, &match?({:fmove, _, {:fr, _}}, &1))
           end)

    assert %{decoded_origin: [[_site, function, "artifact"]]} = DecodedOrigin.extract(data)
    assert function == Argus.InstrId.func_id(module, :artifact, 1)
  end
end
