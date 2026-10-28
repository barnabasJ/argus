defmodule Argus.Extractors.DocsTest do
  use ExUnit.Case, async: true

  alias Argus.Extractor.Helpers
  alias Argus.Extractors.Docs
  alias Argus.Test.Fixtures.ApiSurface

  defp hidden(input) do
    {:ok, facts} = Argus.Pipeline.extract([input], extractors: [Docs])
    facts |> Map.get(:doc_hidden, []) |> Enum.map(fn [func] -> func end) |> Enum.sort()
  end

  test "a @doc false function of a documented module, at each arity its defaults make" do
    assert hidden(ApiSurface) ==
             ["#{inspect(ApiSurface)}:describe/1", "#{inspect(ApiSurface)}:describe/2"]
  end

  test "every function of a @moduledoc false module, and no function the compiler adds" do
    expected =
      for fun <- ~w(event/1 keyword/1 keywords/1 orphan/1 param/1 rules/0 rules/1 word/1),
          do: "#{inspect(ApiSurface.Grammar)}:#{fun}"

    assert hidden(ApiSurface.Grammar) == expected
  end

  test "@impl true hides a callback" do
    assert hidden(ApiSurface.Plug) ==
             ["#{inspect(ApiSurface.Plug)}:call/2", "#{inspect(ApiSurface.Plug)}:init/1"]
  end

  test "a beam without a Docs chunk hides nothing" do
    forms =
      for source <- [~c"-module(argus_docs_test_plain).", ~c"-export([f/1]).", ~c"f(X) -> X."] do
        {:ok, tokens, _} = :erl_scan.string(source)
        {:ok, form} = :erl_parse.parse_form(tokens)
        form
      end

    {:ok, _mod, bin} = :compile.forms(forms, [:binary])
    assert hidden(bin) == []
  end

  @tag :tmp_dir
  test "a missing Docs chunk beyond the filename atom limit extracts without degradation", %{
    tmp_dir: dir
  } do
    forms =
      for source <- [~c"-module(argus_docs_test_long_path).", ~c"-export([f/1]).", ~c"f(X) -> X."] do
        {:ok, tokens, _} = :erl_scan.string(source)
        {:ok, form} = :erl_parse.parse_form(tokens)
        form
      end

    {:ok, module, bytes} = :compile.forms(forms, [:binary, :debug_info])

    assert {:error, :beam_lib, {:missing_chunk, _, ~c"Docs"}} =
             :beam_lib.chunks(bytes, [~c"Docs"])

    path = long_beam_path(dir, "argus_docs_test_long_path.beam")
    File.write!(path, bytes)
    assert String.length(path) > 255
    assert {:ok, ^bytes} = Helpers.beam_source(%{module: module, beam: path})
    assert {:ok, ^bytes} = Helpers.beam_source(%{module: module, beam: bytes})
    assert {:ok, {_module, [debug_info: debug]}} = :beam_lib.chunks(bytes, [:debug_info])
    assert Helpers.debug_info(%{module: module, beam: path}) == {:ok, debug}
    assert {:ok, facts} = Argus.Pipeline.extract([path], extractors: [Docs])
    assert Map.get(facts, :extraction_error, []) == []
    assert Map.get(facts, :doc_hidden, []) == []
  end

  @tag :tmp_dir
  test "documented file, raw bytes and code-path inputs retain identical chunk behavior", %{
    tmp_dir: dir
  } do
    bytes = File.read!(:code.which(ApiSurface))
    path = long_beam_path(dir, "Elixir.Argus.Test.Fixtures.ApiSurface.beam")
    File.write!(path, bytes)
    assert String.length(path) > 255
    assert {:ok, ^bytes} = Helpers.beam_source(%{module: ApiSurface})
    assert {:ok, ^bytes} = Helpers.beam_source(%{module: ApiSurface, beam: path})
    assert hidden(path) == hidden(bytes)
    assert hidden(path) == hidden(ApiSurface)
    assert hidden(path) != []

    assert Helpers.debug_info(%{module: ApiSurface, beam: path}) ==
             Helpers.debug_info(%{module: ApiSurface, beam: bytes})

    assert {:ok, facts} = Argus.Pipeline.extract([path], extractors: [Docs])
    assert Map.get(facts, :extraction_error, []) == []
    assert :error = Helpers.beam_source(%{module: ApiSurface, beam: path <> ".missing"})
    assert :error = Helpers.beam_source(%{module: ApiSurface, beam: Path.dirname(path)})
    assert :error = Helpers.debug_info(%{module: ApiSurface, beam: path <> ".missing"})
  end

  defp long_beam_path(dir, basename) do
    nested =
      Path.join([
        dir,
        String.duplicate("a", 90),
        String.duplicate("b", 90),
        String.duplicate("c", 90)
      ])

    File.mkdir_p!(nested)
    Path.join(nested, basename)
  end
end
