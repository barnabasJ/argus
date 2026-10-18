defmodule Argus.Driver.Preparation do
  @moduledoc false

  alias Argus.Graph
  alias Roux.{Blob, Memo, Runtime, Session}

  @doc false
  @spec run(options :: keyword(), initialize :: function(), finish :: function()) :: term()
  def run(options, initialize, finish) do
    batch_size = Keyword.get(options, :preparation_batch_size, 64)

    if not (is_integer(batch_size) and batch_size > 0) do
      raise ArgumentError, "preparation_batch_size must be a positive integer"
    end

    original = Keyword.get(options, :store) || Graph.store()
    store = if is_binary(original), do: Blob.open!(original), else: original
    shared = if store.temporary?, do: Blob.open!(store.root), else: store

    try do
      with_manifest(shared, options[:manifest], fn manifest ->
        session = Graph.open(store: shared, manifest: manifest, force: options[:force] || false)

        state =
          try do
            initialize.(session)
          rescue
            exception ->
              Session.close(session)
              reraise exception, __STACKTRACE__
          catch
            kind, reason ->
              Session.close(session)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        loop(session, state.keys, state, batch_size, false, [], finish)
      end)
    after
      if store.temporary?, do: Blob.destroy(store)
    end
  end

  defp with_manifest(store, nil, run) do
    Blob.scratch(store, fn directory -> run.(Path.join(directory, "manifest")) end)
  end

  defp with_manifest(_store, manifest, run), do: run.(manifest)

  defp loop(session, remaining, state, size, changed, errors, finish) do
    next =
      try do
        case prepare(session.db, remaining, size, errors) do
          {:checkpoint, rest, errors} ->
            changed = changed or moved?(session)
            Session.commit(session, state.meta)
            {:continue, rest, changed, errors}

          {:complete, errors} ->
            {:done, finish.(session, state, changed or moved?(session), Enum.uniq(errors))}
        end
      after
        Session.close(session)
      end

    case next do
      {:done, result} ->
        result

      {:continue, rest, changed, errors} ->
        restored = Graph.open(store: session.blob, manifest: session.manifest)
        loop(restored, rest, state, size, changed, errors, finish)
    end
  end

  defp prepare(_db, [], _size, errors), do: {:complete, errors}

  defp prepare(db, remaining, size, errors) do
    {batch, rest} = Enum.split(remaining, size)

    {errors, lost?} =
      Enum.reduce([:module_facts, :module_in_process], {errors, false}, fn query,
                                                                           {errors, lost?} ->
        results =
          Runtime.parallel(db, Enum.map(batch, &{query, &1}),
            max_concurrency: System.schedulers_online()
          )

        lost? = lost? or Enum.any?(results, &match?({:ok, %{lost: true}}, &1))

        errors =
          Enum.zip(batch, results)
          |> Enum.reduce(errors, fn {key, result}, errors ->
            case result do
              {:ok, pack} ->
                case Graph.Pack.read_chunks(db, query, key, pack.pack, [:extraction_error]) do
                  {:ok, chunks} ->
                    for [module, step, reason] <-
                          Argus.Tsv.decode(Map.get(chunks, :extraction_error, "")),
                        reduce: errors do
                      errors ->
                        [
                          %{
                            module: Argus.Findings.Anchor.module_atom(module),
                            source: module,
                            step: step,
                            reason: reason
                          }
                          | errors
                        ]
                    end

                  {:error, reason} ->
                    [error(key, reason) | errors]
                end

              {:error, reason} ->
                [error(key, reason) | errors]
            end
          end)

        {errors, lost?}
      end)

    built? =
      Enum.any?(batch, fn key ->
        Enum.any?([:extracted, :in_process], fn kind ->
          match?({:ok, _, _}, Memo.verification_state(db, {:extraction_pack, {key, kind}}))
        end)
      end)

    if built? or lost?, do: {:checkpoint, rest, errors}, else: prepare(db, rest, size, errors)
  end

  defp error(key, reason) do
    %{
      module: nil,
      source: key,
      step: "module",
      reason: reason |> inspect(limit: 20) |> String.replace(~r/\s+/, " ")
    }
  end

  defp moved?(%Session{restored?: false}), do: true

  defp moved?(%Session{db: db} = session) do
    Roux.Revision.current(db.revision) != session.revision or
      Roux.Database.writes(db) != session.writes
  end
end
