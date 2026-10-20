defmodule Argus.Graph.Extraction do
  @moduledoc """
  The producers used by the extraction graph. Query entry points delegate to
  `Argus.Graph.FunctionPack`, which assembles cached function and producer facts.
  """

  alias Argus.Analyses.Coverage
  alias Argus.Analysis.Catalog

  @doc "The full producer inventory: `:base` and `extractors/0`, in that order."
  @spec producers() :: [Argus.Pipeline.producer()]
  def producers, do: [:base | extractors()]

  @doc """
  The full built-in inventory, including coverage and the resource extractors
  used by interactive supervision queries. Graphs without a bounded analysis
  selection retain this inventory; frontends select a subset with `selected/3`.
  """
  @spec extractors() :: [module()]
  def extractors do
    analysis_extractors =
      Enum.flat_map(Argus.Analysis.builtin_analysis_modules(), & &1.extractors())

    ([Argus.Extractors.CallArgs, Argus.Extractors.ETS, Argus.Extractors.ApiCalls] ++
       analysis_extractors)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Producers for a frontend's selected analyses. The native program manifest
  resolves the actual inputs, including shared stages, so imported but unused
  declarations do not cause extraction. Declared extractors are retained even
  when an analysis uses their rows only outside its rule program.

  An unbounded graph, pipeline coverage, an ad-hoc program, or an unreadable
  manifest keeps the full inventory. The normal solve reports manifest failures
  separately.
  """
  @spec selected(
          db :: Roux.Database.t(),
          analyses :: :all | [Argus.Analysis.analysis()],
          supplied :: [module()]
        ) :: [Argus.Pipeline.producer()]
  def selected(_db, :all, supplied), do: Enum.uniq(producers() ++ supplied)

  def selected(db, analyses, supplied) do
    if full_inventory?(analyses) do
      selected(db, :all, supplied)
    else
      declared =
        for analysis <- analyses,
            {:ok, module, _options} <- [Catalog.selection(analysis)],
            extractor <- module.extractors(),
            do: extractor

      # Facts-directory consumers always publish stage 0, even when the selected
      # findings do not read it. Its native input set is small and base-owned.
      case inputs(db, [:stage0 | analyses], MapSet.new(), MapSet.new()) do
        {:ok, relations} ->
          inferred =
            Enum.filter(extractors(), fn extractor ->
              Enum.any?(extractor.relations(), &MapSet.member?(relations, Atom.to_string(&1)))
            end)

          Enum.uniq([:base | declared ++ inferred ++ supplied]) |> Enum.sort()

        {:error, _reason} ->
          selected(db, :all, supplied)
      end
    end
  end

  defp full_inventory?(analyses) do
    Enum.any?(analyses, fn
      {:custom, _path} ->
        true

      analysis ->
        case Catalog.selection(analysis) do
          {:ok, Coverage, _options} -> true
          _other -> false
        end
    end)
  end

  defp inputs(_db, [], _seen, relations), do: {:ok, relations}

  defp inputs(db, [program | rest], seen, relations) do
    if MapSet.member?(seen, program) do
      inputs(db, rest, seen, relations)
    else
      with {:ok, io} <- Roux.Runtime.query(db, :program_io, program) do
        names = Enum.map(io.inputs, &elem(&1, 0))

        points_to = Argus.Analysis.points_to_relations()
        points_to_files = Enum.map(points_to, &(&1 <> ".facts"))

        # Solve routes shared stage inputs by filename. An external analysis
        # can rename the relation while retaining that staged input file.
        stages =
          if Enum.any?(io.inputs, fn {_name, file} -> file in points_to_files end),
            do: [:points_to, :points_to_bounded],
            else: []

        inputs(
          db,
          rest ++ stages,
          MapSet.put(seen, program),
          MapSet.union(relations, MapSet.new(names))
        )
      end
    end
  end

  @spec module_facts(Roux.Database.t(), term()) :: {:ok, Argus.Graph.Pack.t()} | {:error, term()}
  defdelegate module_facts(db, key), to: Argus.Graph.FunctionPack

  @spec module_semantic(Roux.Database.t(), term()) ::
          {:ok, %{atom() => binary()}} | {:error, term()}
  defdelegate module_semantic(db, key), to: Argus.Graph.FunctionPack
end
