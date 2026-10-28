defmodule Argus.ReviewedFindings.File do
  @moduledoc """
  Loads exact review records as JSON data. No file is discovered implicitly.
  Duplicate object keys, malformed records and unreadable configured files fail.
  `load!/2` returns Driver options; it never accepts a supplied run proof.
  """

  @doc "Read the configured JSON once, retaining its byte digest as review provenance."
  @spec load!(Path.t() | nil, Path.t()) :: keyword()
  def load!(nil, _root), do: []

  def load!(path, root) do
    absolute = Path.expand(path, root)

    case File.read(absolute) do
      {:ok, bytes} ->
        records = bytes |> decode!() |> Argus.ReviewedFindings.records!()
        digest = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
        [review_records: records, review_file: %{path: absolute, sha256: digest}]

      {:error, reason} ->
        raise Argus.ConfigError.unreadable(absolute, :file.format_error(reason) |> to_string())
    end
  rescue
    error in ArgumentError ->
      reraise Argus.ConfigError.unreadable(Path.expand(path, root), Exception.message(error)),
              __STACKTRACE__
  end

  defp decode!(bytes) do
    case JSON.decode(bytes, nil,
           object_start: fn _ -> %{} end,
           object_push: &object_push/3,
           object_finish: fn object, parent -> {object, parent} end
         ) do
      {records, nil, rest} ->
        if json_whitespace?(rest),
          do: records,
          else: raise(ArgumentError, "review JSON has trailing content")

      {:error, _reason} ->
        raise ArgumentError, "invalid review JSON"
    end
  end

  defp json_whitespace?(<<>>), do: true

  defp json_whitespace?(<<byte, rest::binary>>) when byte in [0x20, 0x09, 0x0A, 0x0D],
    do: json_whitespace?(rest)

  defp json_whitespace?(_rest), do: false

  defp object_push(key, value, object) do
    if Map.has_key?(object, key), do: raise(ArgumentError, "duplicate review JSON object key")
    Map.put(object, key, value)
  end
end
