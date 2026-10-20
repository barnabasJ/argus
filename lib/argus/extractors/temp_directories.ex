defmodule Argus.Extractors.TempDirectories do
  @moduledoc """
  Temporary-path provenance at calls and returns, using native reaching definitions.

  Sources are a parameter, a project call result, or a `System.tmp_dir/0` or
  `System.tmp_dir!/0` call. Path construction preserves sources; unknown runtime
  functions do not. Container projections and `:filename.join/1` are left
  unresolved because whole-value summaries cannot identify surviving fields or
  components. Datalog composes scalar summaries across project helpers.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Runtime
  alias Argus.Extractor.ValueFlow
  alias Argus.Instr
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  @spec relations() :: [atom()]
  def relations, do: [:tmp_dir_argument, :tmp_dir_return]

  @impl true
  @spec extract(data :: Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(data) do
    case Helpers.reaching(data) do
      nil -> %{}
      reaching -> extract_functions(data, ValueFlow.reads_by_function(reaching))
    end
  end

  defp extract_functions(data, reads) do
    calls = CallSites.for_module(data) |> Enum.group_by(& &1.func_id)

    Enum.reduce(data.functions, %{}, fn {:function, name, arity, _, instrs}, facts ->
      func = InstrId.func_id(data.module, name, arity)
      sites = Map.new(Map.get(calls, func, []), &{&1.idx, &1})
      reads = Map.get(reads, func, %{})
      indexed = Enum.with_index(instrs)
      instructions = List.to_tuple(instrs)

      {outs, _} =
        ValueFlow.solve(Enum.map(indexed, &elem(&1, 1)), reads, nil, fn idx, outs, state ->
          instr = elem(instructions, idx)
          inputs = ValueFlow.inputs(reads, outs, idx, &{:param, to_string(&1)})
          value = written_value(instr, inputs, Map.get(sites, idx), func, idx)

          writes =
            Enum.map(Instr.defs(instr), &{register_name(&1), value_for(&1, instr, inputs, value)})

          {writes, state, []}
        end)

      Enum.reduce(indexed, facts, fn {instr, idx}, acc ->
        inputs = ValueFlow.inputs(reads, outs, idx, &{:param, to_string(&1)})
        site = Map.get(sites, idx)
        acc = arguments(acc, site, inputs)

        cond do
          instr == :return ->
            sources(acc, :tmp_dir_return, [func], Map.get(inputs, "x0", MapSet.new()))

          Instr.tail_call?(instr) and site != nil ->
            sources(acc, :tmp_dir_return, [func], written_value(instr, inputs, site, func, idx))

          true ->
            acc
        end
      end)
    end)
    |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.uniq() |> Enum.sort()} end)
  end

  defp written_value(_instr, _inputs, %{mfa: {System, name, 0}}, func, idx)
       when name in [:tmp_dir, :tmp_dir!],
       do: MapSet.new([{:root, InstrId.mint(func, idx)}])

  defp written_value(_instr, inputs, %{mfa: {mod, name, arity}} = site, func, idx) do
    cond do
      path_constructor?(mod, name) -> path_inputs(inputs, site, arity)
      not Runtime.module?(mod) -> MapSet.new([{:call, InstrId.mint(func, idx)}])
      true -> MapSet.new()
    end
  end

  defp written_value(instr, inputs, nil, _func, _idx) do
    # These summaries name whole-value sources, not container fields. A selected
    # field must not inherit the roots carried by an unrelated sibling field.
    if container_projection?(instr), do: MapSet.new(), else: union(inputs)
  end

  defp container_projection?(instr) when is_tuple(instr) do
    case elem(instr, 0) do
      op when op in [:get_map_elements, :get_tuple_element, :get_list, :get_hd, :get_tl] -> true
      op when op in [:bif, :gc_bif] -> elem(instr, 1) in [:map_get, :element, :hd, :tl]
      _ -> false
    end
  end

  defp container_projection?(_instr), do: false

  # An absolute first argument ignores expand/2's base. A literal lets native
  # register resolution establish that case; unknown first arguments retain both.
  defp path_inputs(inputs, %{mfa: {mod, name, 2}} = site, 2)
       when (mod == Path and name in [:expand, :absname]) or
              (mod == :filename and name == :absname) do
    case Resolve.resolve_register(site.instrs, site.idx, {:x, 0}) do
      {:ok, path} when is_binary(path) or is_list(path) ->
        if absolute_literal?(path),
          do: Map.get(inputs, "x0", MapSet.new()),
          else: union(inputs)

      _ ->
        union(inputs)
    end
  end

  defp path_inputs(inputs, %{mfa: {:filename, :join, 2}} = site, 2) do
    case Resolve.resolve_register(site.instrs, site.idx, {:x, 1}) do
      {:ok, path} when is_binary(path) or is_list(path) ->
        if absolute_literal?(path),
          do: Map.get(inputs, "x1", MapSet.new()),
          else: union(inputs)

      _ ->
        union(inputs)
    end
  end

  # filename.join/1 can discard earlier list elements at a later absolute
  # component. Whole-list provenance cannot establish which roots survive.
  defp path_inputs(_inputs, %{mfa: {:filename, :join, 1}}, 1), do: MapSet.new()

  defp path_inputs(inputs, _site, _arity), do: union(inputs)

  defp absolute_literal?(path) when is_binary(path), do: :filename.pathtype(path) == :absolute

  defp absolute_literal?(path) when is_list(path),
    do: :io_lib.char_list(path) and :filename.pathtype(path) == :absolute

  defp path_constructor?(Path, name), do: name in [:join, :expand, :absname]
  defp path_constructor?(:filename, name), do: name in [:join, :absname]
  defp path_constructor?(_, _), do: false

  defp value_for(reg, instr, inputs, value) do
    case Instr.copy_source(instr, reg) do
      nil ->
        value

      {kind, number} = source when kind in [:x, :y, :fr] and is_integer(number) ->
        Map.get(inputs, register_name(source), MapSet.new())

      _literal ->
        MapSet.new()
    end
  end

  defp arguments(facts, nil, _inputs), do: facts

  defp arguments(facts, site, inputs) do
    {mod, name, arity} = site.mfa
    callee = InstrId.func_id(mod, name, arity)
    id = InstrId.mint(site.func_id, site.idx)

    Enum.reduce(0..(arity - 1)//1, facts, fn pos, acc ->
      sources(
        acc,
        :tmp_dir_argument,
        [id, site.func_id, callee, to_string(pos)],
        Map.get(inputs, "x#{pos}", MapSet.new())
      )
    end)
  end

  defp sources(facts, relation, prefix, values) do
    Enum.reduce(values, facts, fn {kind, source}, acc ->
      add_fact(acc, relation, prefix ++ [Atom.to_string(kind), source])
    end)
  end

  defp register_name(reg) do
    {kind, number} = Instr.register(reg)
    "#{kind}#{number}"
  end

  defp union(inputs),
    do: Enum.reduce(inputs, MapSet.new(), fn {_, values}, acc -> MapSet.union(acc, values) end)
end
