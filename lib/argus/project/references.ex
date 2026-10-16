defmodule Argus.Project.References do
  @moduledoc "Native module-input closure declared by selected extractors."

  alias Argus.Analysis.Catalog
  alias Argus.Specs.Source
  alias Roux.{Input, Runtime, Sources}

  @doc "Prepare each selection's native program without widening unrelated analyses."
  @spec prepare(
          map(),
          Source.t(),
          [term()],
          map(),
          map(),
          map(),
          [term()],
          (binary() -> binary()),
          map()
        ) ::
          map()
  def prepare(
        db,
        source,
        original,
        files,
        prior_sources,
        meta,
        analyses,
        input_hash,
        selected_files
      ) do
    Enum.each(original, &Input.set(db, :module_role, &1, :project))

    initial = %{
      files: files,
      meta: meta,
      programs: %{},
      errors: %{},
      incomplete: %{},
      unreadable: MapSet.new(),
      original: MapSet.new(original),
      input_hash: input_hash
    }

    result =
      Enum.reduce(analyses, initial, fn selection, state ->
        {:ok, module, _options} = Catalog.selection(selection)
        producers = module.extractors()

        if Enum.any?(
             producers,
             &(Code.ensure_loaded?(&1) and function_exported?(&1, :references, 1))
           ) do
          program = {:analysis_inputs, :project, selection}

          result =
            try do
              close(db, source, producers, original, MapSet.new(), [], state, prior_sources)
            rescue
              exception -> {:error, {:reference_declaration, exception.__struct__}, state}
            end

          case result do
            {:ok, keys, missing, state} ->
              Input.set(db, :program, program, keys)
              Input.set(db, :missing_modules, program, missing)
              Input.set(db, :analysis_program, {:project, selection}, program)
              state = put_in(state.programs[selection], program)
              if missing == [], do: state, else: put_in(state.incomplete[selection], missing)

            {:error, reason, state} ->
              Input.set(db, :program, program, [])
              Input.set(db, :analysis_program, {:project, selection}, program)
              Input.set(db, :missing_modules, program, reason)
              put_in(state.errors[selection], {:required_module_inputs, reason})
          end
        else
          Input.set(db, :analysis_program, {:project, selection}, :project)
          put_in(state.programs[selection], :project)
        end
      end)

    used =
      Enum.flat_map(result.programs, fn {_selection, program} ->
        Runtime.input(db, :program, program, default: [])
      end)

    files = Map.take(result.files, Enum.uniq(Map.keys(selected_files) ++ used))
    %{meta: meta} = sync(db, files, prior_sources, input_hash)
    %{result | files: files, meta: meta}
  end

  defp close(_db, _source, _producers, [], seen, missing, state, _prior),
    do:
      {:ok, seen |> MapSet.difference(state.unreadable) |> MapSet.to_list() |> Enum.sort(),
       Enum.sort(Enum.uniq(missing)), state}

  defp close(db, source, producers, [key | rest], seen, missing, state, prior) do
    cond do
      MapSet.member?(seen, key) ->
        close(db, source, producers, rest, seen, missing, state, prior)

      MapSet.size(seen) >= 16_384 ->
        {:error, :reference_closure_limit, state}

      true ->
        seen = MapSet.put(seen, key)

        case Runtime.query(db, :extraction_references, {key, producers}) do
          {:ok, modules} ->
            previous_files = state.files

            {added, failures, state} =
              Enum.reduce(modules, {[], [], state}, fn module, {keys, failures, state} ->
                case resolve(source, module) do
                  {:ok, path} when is_binary(path) ->
                    path = Path.expand(path)
                    files = Map.put(state.files, path, path)
                    state = %{state | files: files}
                    role = if MapSet.member?(state.original, path), do: :project, else: :reference
                    Input.set(db, :module_role, path, role)
                    {[path | keys], failures, state}

                  _ ->
                    {keys, [{module, :missing} | failures], state}
                end
              end)

            state =
              if state.files != previous_files do
                %{meta: meta} = sync(db, state.files, prior, state.input_hash)
                %{state | meta: meta}
              else
                state
              end

            failures =
              failures ++
                for(
                  path <- added,
                  is_binary(path),
                  not Map.has_key?(state.meta, path),
                  do: {path, :missing}
                )

            close(
              db,
              source,
              producers,
              rest ++ Enum.reverse(added),
              seen,
              missing ++ failures,
              state,
              prior
            )

          {:error, _reason} ->
            state = %{state | unreadable: MapSet.put(state.unreadable, key)}
            close(db, source, producers, rest, seen, [{key, :unreadable} | missing], state, prior)
        end
    end
  end

  # Source already identified these as the analyzer runtime's own modules.
  # Resolve their file through the native code server without loading a module.
  defp resolve(source, module) do
    case Source.which(source, module) do
      {:ok, :runtime} ->
        case :code.which(module) do
          path when is_list(path) -> {:ok, List.to_string(path)}
          _ -> :error
        end

      found ->
        found
    end
  end

  defp sync(db, files, prior, input_hash) do
    Sources.sync(db, :beam, files, prior,
      hash: input_hash,
      value: fn %{hash: hash} -> %{hash: hash} end
    )
  end
end
