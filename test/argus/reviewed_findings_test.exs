defmodule Argus.ReviewedFindingsTest do
  use ExUnit.Case, async: true

  alias Argus.Findings.Build
  alias Argus.ReviewedFindings
  alias Argus.ReviewedFindings.Identity

  defp outputs do
    Argus.Analyses.Blocking.output_relations()
    |> Map.new(&{Atom.to_string(&1.name), []})
    |> Map.put("sync_call_fan_in", [["Target", "5", "bounded"]])
    |> Map.put("bottleneck_caller", [
      ["A", "Target", "A:call/0"],
      ["A", "Target", "A:other/0"],
      ["B", "Target", "B:call/0"]
    ])
  end

  defp candidate(outputs, proof \\ %{inventory: %{Target => "source"}, rules: "rules"}) do
    {[finding], []} = Build.with_review_identity(Argus.Analyses.Blocking, outputs)

    data =
      Map.put(proof, :analyses, %{
        blocking: %{
          module: Argus.Analyses.Blocking,
          census: ReviewedFindings.digest(finding.review_identity.census)
        }
      })

    binding = %{version: 1, complete?: true, digest: ReviewedFindings.digest(data), binding: data}
    ReviewedFindings.candidate(finding.review_identity, binding)
  end

  defp record(candidate) do
    Map.merge(candidate, %{
      "decision" => "false_positive",
      "justification" => "The independently reviewed callback host allocates each keyed instance."
    })
  end

  test "ordinary native builders retain their exact findings shape and evidence" do
    {ordinary, []} = Build.build(Argus.Analyses.Blocking, outputs())
    {reviewable, []} = Build.with_review_identity(Argus.Analyses.Blocking, outputs())
    assert Enum.map(reviewable, &Map.delete(&1, :review_identity)) == ordinary
    assert [%{related: [_, _]}] = ordinary
    refute Map.has_key?(hd(ordinary), :review_identity)
  end

  test "nonrepresentative evidence changes invalidate the review at the same caller count" do
    before = outputs()

    after_change =
      Map.update!(before, "bottleneck_caller", fn rows ->
        List.replace_at(rows, 1, ["A", "Target", "A:z_other/0"])
      end)

    # The existing native evidence renderer deduplicates A to A:call/0 in both.
    assert Build.build(Argus.Analyses.Blocking, before) ==
             Build.build(Argus.Analyses.Blocking, after_change)

    refute candidate(before) == candidate(after_change)

    assert_raise ArgumentError, ~r/stale review/, fn ->
      ReviewedFindings.match!([candidate(after_change)], [record(candidate(before))])
    end
  end

  test "primary row deduplication cannot discard a changed witness" do
    row = [
      "A",
      "B",
      "A:handle_call/3",
      "B:handle_call/3",
      "call",
      "A:handle_call/3#1",
      "B:handle_call/3#1"
    ]

    second = List.replace_at(row, 5, "A:handle_call/3#9")
    original = Map.put(outputs(), "call_cycle", [row, second])

    changed =
      Map.put(original, "call_cycle", [row, List.replace_at(second, 5, "A:handle_call/3#10")])

    assert Build.build(Argus.Analyses.Blocking, original) ==
             Build.build(Argus.Analyses.Blocking, changed)

    refute Identity.census!(Argus.Analyses.Blocking, original) ==
             Identity.census!(Argus.Analyses.Blocking, changed)
  end

  test "raw row ordering is stable while additional witnesses invalidate identity" do
    original = outputs()
    reordered = Map.new(original, fn {name, rows} -> {name, Enum.reverse(rows)} end)
    assert candidate(original) == candidate(reordered)
    additional = Map.update!(original, "bottleneck_caller", &(&1 ++ [["A", "Target", "A:z/0"]]))
    refute candidate(original) == candidate(additional)
  end

  test "exact justified reviews remain visible; unreviewed diagnostics remain separate" do
    first = candidate(outputs())
    second = candidate(outputs(), %{inventory: %{Target => "changed"}, rules: "rules"})
    assert [reviewed, unreviewed] = ReviewedFindings.match!([first, second], [record(first)])
    assert reviewed.status == :reviewed
    assert reviewed.review["justification"] == record(first)["justification"]
    assert reviewed.candidate == first
    assert unreviewed.status == :unreviewed
    assert unreviewed.candidate == second

    assert ReviewedFindings.match!([first], []) == [
             %{candidate: first, status: :unreviewed, review: nil}
           ]
  end

  test "source, contract, rule and policy mutations cannot reuse an exact review" do
    original = candidate(outputs(), %{source: "v1", contract: "v1", rules: "v1", policy: "v1"})

    for key <- [:source, :contract, :rules, :policy] do
      modified = Map.put(%{source: "v1", contract: "v1", rules: "v1", policy: "v1"}, key, "v2")

      assert_raise ArgumentError, ~r/stale review/, fn ->
        ReviewedFindings.match!([candidate(outputs(), modified)], [record(original)])
      end
    end
  end

  test "missing proof, malformed rows, opaque values and missing relations fail closed" do
    assert_raise ArgumentError, fn -> ReviewedFindings.candidate(%{}, nil) end
    assert_raise ArgumentError, fn -> ReviewedFindings.digest(self()) end
    assert_raise ArgumentError, fn -> ReviewedFindings.digest(fn -> :ok end) end
    assert_raise ArgumentError, fn -> Identity.census!(Argus.Analyses.Blocking, %{}) end

    assert_raise ArgumentError, fn ->
      Identity.census!(Argus.Analyses.Blocking, Map.put(outputs(), "bottleneck_caller", [["A"]]))
    end
  end

  test "valid native-shaped proof cannot certify a missing, malformed or inconsistent witness census" do
    {[finding], []} = Build.with_review_identity(Argus.Analyses.Blocking, outputs())
    identity = finding.review_identity

    data = %{
      analyses: %{
        blocking: %{
          module: Argus.Analyses.Blocking,
          census: ReviewedFindings.digest(identity.census)
        }
      }
    }

    proof = %{version: 1, complete?: true, digest: ReviewedFindings.digest(data), binding: data}
    assert ReviewedFindings.candidate(identity, proof)

    censuses = [
      Map.update!(identity.census, :outputs, &Map.delete(&1, "bottleneck_caller")),
      Map.update!(identity.census, :outputs, &Map.put(&1, "bottleneck_caller", [["A"]])),
      Map.update!(identity.census, :outputs, &Map.put(&1, "bottleneck_caller", [])),
      Map.update!(
        identity.census,
        :relations,
        &Enum.reject(&1, fn r -> r.name == :bottleneck_caller end)
      ),
      Map.update!(identity.census, :outputs, &Map.put(&1, "unknown", []))
    ]

    for census <- censuses do
      assert_raise ArgumentError, fn ->
        ReviewedFindings.candidate(%{identity | census: census}, proof)
      end
    end
  end

  test "stale, ambiguous, wildcard, duplicate and unjustified records are rejected" do
    current = candidate(outputs())
    exact = record(current)
    assert_raise ArgumentError, fn -> ReviewedFindings.match!([], [exact]) end
    assert_raise ArgumentError, fn -> ReviewedFindings.match!([current, current], [exact]) end
    assert_raise ArgumentError, fn -> ReviewedFindings.records!([exact, exact]) end

    assert_raise ArgumentError, fn ->
      ReviewedFindings.records!([Map.put(exact, "module", "Target")])
    end

    assert_raise ArgumentError, fn ->
      ReviewedFindings.records!([Map.put(exact, "fingerprint", "*")])
    end

    assert_raise ArgumentError, fn ->
      ReviewedFindings.records!([Map.put(exact, "justification", " ")])
    end
  end

  test "review versions and candidate matching preserve exact integer type" do
    current = candidate(outputs())
    exact = record(current)

    assert_raise ArgumentError, fn ->
      ReviewedFindings.records!([Map.put(exact, "version", 1.0)])
    end

    assert_raise ArgumentError, fn ->
      ReviewedFindings.match!([current], [Map.put(exact, "version", 1.0)])
    end

    assert_raise ArgumentError, fn ->
      ReviewedFindings.match!([Map.put(current, "version", 1.0)], [exact])
    end
  end
end
