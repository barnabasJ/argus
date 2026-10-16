defmodule Argus.Extractor.Reads do
  @moduledoc false

  @key {__MODULE__, :beam_reads}

  @doc false
  @spec track((term() -> {term(), term()}), (-> term())) :: {term(), [{term(), term()}]}
  def track(reader, compute) do
    previous = Process.get(@key)
    Process.put(@key, %{reader: reader, reads: %{}})

    try do
      result = compute.()
      {result, Process.get(@key).reads |> Enum.sort()}
    after
      if previous == nil, do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  @doc false
  @spec read_beam(module() | Path.t() | charlist() | binary()) ::
          {:ok, binary()} | {:error, term()}
  def read_beam(<<"FOR1", _size::32, "BEAM", _rest::binary>> = bytes), do: {:ok, bytes}

  def read_beam(input) do
    case Process.get(@key) do
      nil ->
        elem(read(input), 0)

      %{reader: reader, reads: reads} = context ->
        {result, identity} = reader.(input)

        case Map.fetch(reads, input) do
          {:ok, prior} when prior != identity -> raise "Referenced BEAM changed during extraction"
          _ -> :ok
        end

        Process.put(@key, %{context | reads: Map.put(reads, input, identity)})
        result
    end
  end

  @doc false
  @spec read(term(), Argus.Specs.Source.t() | nil) :: {term(), term()}
  def read(input, source \\ nil)

  def read(module, source) when is_atom(module) do
    path =
      case source do
        nil ->
          case :code.which(module) do
            path when is_list(path) -> {:ok, List.to_string(path)}
            _ -> :error
          end

        source ->
          case Argus.Specs.Source.which(source, module) do
            {:ok, :runtime} ->
              case :code.which(module) do
                path when is_list(path) -> {:ok, List.to_string(path)}
                _ -> :error
              end

            found ->
              found
          end
      end

    case path do
      {:ok, path} when is_binary(path) -> read(path, source)
      _ -> {{:error, :enoent}, :missing}
    end
  end

  def read(path, _source) when is_list(path), do: read(List.to_string(path))

  def read(path, _source) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> {{:ok, bytes}, {:sha256, :crypto.hash(:sha256, bytes)}}
      {:error, reason} -> {{:error, reason}, {:missing, reason}}
    end
  end

  def read(_input, _source), do: {{:error, :badarg}, :invalid}
end
