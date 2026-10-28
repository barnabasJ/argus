defmodule Argus.ReviewedFindings.Identity do
  @moduledoc """
  Raw diagnostic identity before rendering, row-key deduplication or evidence
  display limits. The complete output relation census is deliberately bound:
  a nonrepresentative witness change invalidates a review too.
  """

  @doc "Capture every raw output, with deterministic relation and row ordering."
  def census!(mod, results) do
    relations = mod.output_relations()
    names = Enum.map(relations, &Atom.to_string(&1.name))

    unless is_map(results) and Enum.sort(Map.keys(results)) == Enum.sort(names) and
             length(names) == length(Enum.uniq(names)) do
      raise ArgumentError, "argus review: exact complete declared output set is required"
    end

    outputs =
      for relation <- relations, into: %{} do
        name = Atom.to_string(relation.name)
        rows = Map.fetch!(results, name)

        unless is_list(rows) and
                 Enum.all?(rows, fn row ->
                   is_list(row) and length(row) == length(relation.fields) and
                     Enum.all?(row, &is_binary/1)
                 end) do
          raise ArgumentError, "argus review: incomplete or malformed output #{name}"
        end

        {name, Enum.sort(rows)}
      end

    %{analysis: mod.name(), module: mod, relations: relations, outputs: outputs}
  end

  @doc "Reject incomplete identity before it can become a review candidate."
  def validate!(
        %{
          version: 1,
          analysis: analysis,
          relation: relation,
          row: row,
          census:
            %{analysis: analysis, module: mod, relations: relations, outputs: outputs} = census
        } = identity
      )
      when is_atom(analysis) and is_atom(relation) and is_atom(mod) and
             is_list(row) and is_list(relations) and is_map(outputs) do
    unless Enum.sort(Map.keys(identity)) ==
             Enum.sort([:version, :analysis, :relation, :row, :census]) and
             function_exported?(mod, :name, 0) and function_exported?(mod, :output_relations, 0) and
             mod.name() == analysis and relations == mod.output_relations() and
             census!(mod, outputs) == census do
      raise ArgumentError, "argus review: incomplete or inconsistent native output census"
    end

    declaration = Enum.find(relations, &(&1.name == relation))

    unless primary_row_present?(declaration, outputs, relation, row) do
      raise ArgumentError, "argus review: primary row is missing from native findings"
    end

    :ok
  end

  def validate!(_identity), do: raise(ArgumentError, "argus review: incomplete raw identity")

  defp primary_row_present?(declaration, outputs, relation, row) do
    declaration && not Map.has_key?(declaration, :evidence) &&
      not Map.has_key?(declaration, :retier) &&
      row in Argus.Findings.Rows.dedupe(
        declaration,
        Map.fetch!(outputs, Atom.to_string(relation))
      )
  end

  @doc "A diagnostic's raw primary row and complete pre-deduplication census."
  def for_row(census, relation, row) do
    %{version: 1, analysis: census.analysis, relation: relation.name, row: row, census: census}
  end
end
