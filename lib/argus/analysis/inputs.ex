defmodule Argus.Analysis.Inputs do
  @moduledoc false

  @spec prepare(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(module, options) do
    result =
      if function_exported?(module, :input_facts, 1),
        do: module.input_facts(options),
        else: %{facts: %{}}

    case result do
      %{facts: facts} when is_map(facts) ->
        if Map.keys(result) -- [:facts, :schemas] != [],
          do: raise(ArgumentError, "unknown input_facts result keys")

        validate_schemas!(Map.get(result, :schemas, []))
        names = Enum.map(Map.keys(facts), &name/1)

        if length(Enum.uniq(names)) == length(names) do
          {:ok, Map.put(result, :facts, Map.new(facts, fn {key, rows} -> {name(key), rows} end))}
        else
          {:error, {:analysis_inputs, "duplicate relation names"}}
        end

      _ ->
        {:error, {:analysis_inputs, "input_facts must return %{facts: map}"}}
    end
  rescue
    error -> {:error, {:analysis_inputs, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:analysis_inputs, Exception.format_banner(kind, reason)}}
  end

  @spec validate(map(), map(), [module() | :base]) :: :ok | {:error, term()}
  def validate(policy, io, producers) do
    protected =
      Enum.map(Argus.Schema.all(), &name(&1.name)) ++
        Argus.Analysis.stage0_relations() ++
        Argus.Analysis.points_to_relations() ++
        Enum.flat_map(producers -- [:base], fn producer ->
          Enum.map(producer.relations(), &name/1)
        end)

    declarations = Map.new(io.relations, &{name(&1.name), &1.columns})

    Enum.reduce_while(policy.facts, :ok, fn {relation, rows}, :ok ->
      columns = Map.get(declarations, relation) || descriptor(policy, relation)

      cond do
        relation in protected ->
          {:halt, {:error, {:analysis_inputs, "cannot overwrite extracted relation #{relation}"}}}

        is_nil(columns) ->
          {:halt, {:error, {:analysis_inputs, "undeclared input relation #{relation}"}}}

        not valid_rows?(rows, columns) ->
          {:halt, {:error, {:analysis_inputs, "invalid rows for #{relation}"}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_schemas!(schemas) when is_list(schemas) do
    names =
      Enum.map(schemas, fn
        %{name: relation, fields: fields} when is_list(fields) and fields != [] ->
          if not Enum.all?(fields, fn field ->
               field_kind(field) in [:symbol, :number, :instr_id, :func_id, :label]
             end),
             do: raise(ArgumentError, "invalid input schema fields")

          name(relation)

        _ ->
          raise ArgumentError, "expected input schemas with name and nonempty fields"
      end)

    if Enum.uniq(names) != names, do: raise(ArgumentError, "duplicate input schemas")
  end

  defp validate_schemas!(_schemas), do: raise(ArgumentError, "schemas must be a list")

  defp descriptor(policy, relation) do
    Enum.find_value(Map.get(policy, :schemas, []), fn schema ->
      if name(schema.name) == relation, do: schema.fields
    end)
  end

  defp valid_rows?(rows, columns) when is_list(rows) do
    Enum.all?(rows, fn row ->
      is_list(row) and length(row) == length(columns) and
        Enum.all?(Enum.zip(row, columns), fn {value, column} -> valid_field?(value, column) end)
    end)
  end

  defp valid_rows?(_, _), do: false

  defp valid_field?(value, column) when is_binary(value) do
    type = field_kind(column)

    case type do
      type when type in [:number, :label, "number"] ->
        case Integer.parse(value) do
          {number, ""} when number >= -2_147_483_648 and number <= 2_147_483_647 -> true
          _ -> false
        end

      type when type in [:symbol, :instr_id, :func_id, "symbol"] ->
        true

      _ ->
        false
    end
  end

  defp valid_field?(_, _), do: false

  defp field_kind(%{"type" => type}), do: field_kind(type)
  defp field_kind(%{type: type}), do: field_kind(type)
  defp field_kind({_name, type, _doc}), do: field_kind(type)
  defp field_kind({_name, type}), do: field_kind(type)
  defp field_kind("symbol"), do: :symbol
  defp field_kind("number"), do: :number
  defp field_kind(type), do: type

  defp name(value) when is_atom(value), do: value |> Atom.to_string() |> String.downcase()
  defp name(value) when is_binary(value), do: String.downcase(value)
end
