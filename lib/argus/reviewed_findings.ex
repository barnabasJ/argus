defmodule Argus.ReviewedFindings do
  @moduledoc """
  Exact, justified reviews of complete diagnostics. Reviews remain visible;
  they are never module or function exclusions. Missing proof rejects a review.

  Configure `reviewed_findings: "argus-reviews.json"` to load exact JSON data.
  The actual Driver produces the complete current proof and matches each record.
  Frontends retain every finding, its severity, review status and justification;
  only unreviewed findings contribute to their existing diagnostic gates.
  """

  @record_keys ~w(version fingerprint proof decision justification)

  @doc "A portable digest of primitive data; opaque runtime values are rejected."
  def digest(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Validate review records decoded from JSON, without evaluating project code."
  def records!(records) when is_list(records) do
    checked = Enum.map(records, &record!/1)
    fingerprints = Enum.map(checked, & &1["fingerprint"])

    if Enum.uniq(fingerprints) != fingerprints do
      invalid!("duplicate reviewed diagnostic fingerprint")
    end

    checked
  end

  def records!(_records), do: invalid!("reviews must be a list of exact records")

  @doc """
  Bind a raw diagnostic identity to a verified run proof. This is a review
  candidate, not an accepted review or an authorization to change a gate.
  """
  def candidate(identity, %{version: 1, complete?: true, digest: proof, binding: binding})
      when is_map(identity) and is_binary(proof) do
    unless sha256?(proof), do: invalid!("invalid run proof digest")
    Argus.ReviewedFindings.Identity.validate!(identity)
    unless digest(binding) == proof, do: invalid!("run proof binding does not match its digest")

    analysis = get_in(binding, [:analyses, identity.analysis])

    unless is_map(analysis) and analysis[:module] == identity.census.module and
             analysis[:census] == digest(identity.census) do
      invalid!("raw diagnostic census does not match the native run proof")
    end

    %{
      "version" => 1,
      "fingerprint" => digest({1, identity, proof}),
      "proof" => proof
    }
  end

  def candidate(_identity, _proof), do: invalid!("complete native run proof is required")

  @doc """
  Match all reviews exactly once against candidates. Stale, missing and ambiguous
  records raise; a new unreviewed finding remains in the returned list unchanged.
  Every finding remains visible with its candidate and optional review reason.
  """
  def match!(candidates, records) when is_list(candidates) do
    records = records!(records)
    grouped = Enum.group_by(candidates, & &1["fingerprint"])

    Enum.each(records, fn record ->
      case Map.get(grouped, record["fingerprint"], []) do
        [candidate] ->
          unless Map.take(record, ~w(version fingerprint proof)) === candidate do
            invalid!("review does not match the current run proof")
          end

        [] ->
          invalid!("stale review has no current diagnostic")

        _multiple ->
          invalid!("review matches multiple diagnostics")
      end
    end)

    by_fingerprint = Map.new(records, &{&1["fingerprint"], &1})

    Enum.map(candidates, fn candidate ->
      case Map.fetch(by_fingerprint, candidate["fingerprint"]) do
        {:ok, record} -> %{candidate: candidate, status: :reviewed, review: record}
        :error -> %{candidate: candidate, status: :unreviewed, review: nil}
      end
    end)
  end

  defp record!(record) when is_map(record) do
    unless Enum.sort(Map.keys(record)) == Enum.sort(@record_keys) and
             record["version"] === 1 and record["decision"] == "false_positive" and
             sha256?(record["fingerprint"]) and sha256?(record["proof"]) and
             is_binary(record["justification"]) and String.trim(record["justification"]) != "" do
      invalid!(
        "review requires exact version, fingerprint, proof, false_positive decision and justification"
      )
    end

    record
  end

  defp record!(_record), do: invalid!("review must be an exact record")

  defp sha256?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp sha256?(_value), do: false

  defp canonical(value) when is_binary(value) or is_integer(value) or is_atom(value), do: value
  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(value) when is_tuple(value),
    do: {:tuple, value |> Tuple.to_list() |> canonical()}

  defp canonical(value) when is_map(value) and not is_struct(value) do
    {:map,
     value |> Enum.map(fn {key, item} -> {canonical(key), canonical(item)} end) |> Enum.sort()}
  end

  defp canonical(_value), do: invalid!("review proof contains nonportable or opaque data")

  defp invalid!(message), do: raise(ArgumentError, "argus review: " <> message)
end
