defmodule Argus.ReviewedFindingsFileTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Argus.ReviewedFindings.File, as: ReviewFile

  test "no file means no IO; exact data carries its actual byte provenance", %{tmp_dir: dir} do
    assert ReviewFile.load!(nil, Path.join(dir, "missing")) == []
    path = Path.join(dir, "reviews.json")
    File.write!(path, "[]\n")
    options = ReviewFile.load!("reviews.json", dir)
    assert options[:review_records] == []
    assert options[:review_file].path == path

    assert options[:review_file].sha256 ==
             :sha256 |> :crypto.hash("[]\n") |> Base.encode16(case: :lower)
  end

  test "duplicate JSON keys and malformed or executable input fail as configuration", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "reviews.json")

    for input <- [
          "[",
          "{}",
          "null",
          "[] true",
          "System.cmd(\"touch\", [])",
          "[{\"version\":1,\"version\":1}]"
        ] do
      File.write!(path, input)
      assert_raise Argus.ConfigError, fn -> ReviewFile.load!(path, dir) end
    end

    File.rm!(path)
    assert_raise Argus.ConfigError, fn -> ReviewFile.load!(path, dir) end
  end

  test "records reject unknown keys, missing reason and duplicate exact fingerprints", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "reviews.json")

    record = %{
      "version" => 1,
      "fingerprint" => String.duplicate("a", 64),
      "proof" => String.duplicate("b", 64),
      "decision" => "false_positive",
      "justification" => "Exact reviewed fixture."
    }

    for records <- [
          [Map.put(record, "mfa", "*")],
          [Map.delete(record, "justification")],
          [record, record]
        ] do
      File.write!(path, JSON.encode!(records))
      assert_raise Argus.ConfigError, fn -> ReviewFile.load!(path, dir) end
    end
  end

  test "literal floating version and non-JSON trailing whitespace fail", %{tmp_dir: dir} do
    path = Path.join(dir, "reviews.json")

    floating_version =
      ~s([{"version":1.0,"fingerprint":"#{String.duplicate("a", 64)}","proof":"#{String.duplicate("b", 64)}","decision":"false_positive","justification":"Exact reviewed fixture."}])

    for input <- [floating_version, "[]" <> <<0xC2, 0xA0>>] do
      File.write!(path, input)
      assert_raise Argus.ConfigError, fn -> ReviewFile.load!(path, dir) end
    end
  end

  test "the four ASCII JSON whitespace bytes remain valid after a document", %{tmp_dir: dir} do
    path = Path.join(dir, "reviews.json")
    File.write!(path, "[]" <> <<0x20, 0x09, 0x0A, 0x0D>>)
    assert ReviewFile.load!(path, dir)[:review_records] == []
  end
end
