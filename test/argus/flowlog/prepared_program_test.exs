defmodule Argus.FlowLog.PreparedProgramTest do
  use ExUnit.Case, async: true

  alias Argus.Dl.Program, as: DlProgram
  alias Argus.FlowLog
  alias Argus.FlowLog.Program
  alias Argus.FlowLog.Toolchain

  @moduletag :tmp_dir

  test "installed sibling priv links resolve lexical parent includes from captured bytes", %{
    tmp_dir: tmp
  } do
    {root, leaf} = linked_program!(tmp)
    snapshot = DlProgram.snapshot(root)

    assert File.read!(Path.join(Path.dirname(root), "../../two/priv/rule.dl")) =~
             "wrong-physical-target"

    assert [
             _,
             %{content: ".decl out(x:symbol)\nout(x) :- input(x), x = \"first\".\n.output out\n"}
           ] = snapshot.files

    File.write!(leaf, ".decl out(x:symbol)\nout(\"second\").\n.output out\n")

    prepared = Program.prepare(toolchain(tmp), snapshot)
    [_, included] = snapshot.files

    prepared_leaf =
      Enum.find_value(prepared.sources, fn {path, original} ->
        if original == included.path, do: path
      end)

    assert File.read!(prepared_leaf) == included.content
    assert String.contains?(File.read!(prepared.path), ~s|.include "#{prepared_leaf}"|)
    assert line_count(File.read!(prepared.path)) == line_count(hd(snapshot.files).content)
    assert Program.prepare(toolchain(tmp), snapshot).path == prepared.path
    refute Program.prepare(toolchain(tmp), root).path == prepared.path
    assert DlProgram.declared_digest(snapshot, []) != DlProgram.declared_digest(root, [])
  end

  test "diamonds deduplicate physical aliases while distinct equal files remain distinct", %{
    tmp_dir: tmp
  } do
    root = Path.join(tmp, "root.dl")
    File.write!(Path.join(tmp, "leaf.dl"), ".decl leaf(x:symbol)\n")
    File.ln_s!("leaf.dl", Path.join(tmp, "alias.dl"))
    File.write!(Path.join(tmp, "same.dl"), File.read!(Path.join(tmp, "leaf.dl")))
    File.write!(Path.join(tmp, "left.dl"), ".include \"leaf.dl\"\n")
    File.write!(Path.join(tmp, "right.dl"), ".include \"alias.dl\"\n.include \"same.dl\"\n")
    File.write!(root, ".include \"left.dl\"\n.include \"right.dl\"\n")
    snapshot = DlProgram.snapshot(root)

    assert Enum.map(snapshot.files, & &1.spelled) == [
             "root.dl",
             "left.dl",
             "leaf.dl",
             "right.dl",
             "same.dl"
           ]

    prepared = Program.prepare(toolchain(tmp), snapshot)
    assert map_size(prepared.sources) == 5

    assert Enum.count(prepared.sources, fn {path, _} ->
             File.read!(path) == ".decl leaf(x:symbol)\n"
           end) == 2
  end

  test "concurrent publishers expose one complete immutable graph", %{tmp_dir: tmp} do
    {root, _leaf} = linked_program!(tmp)
    snapshot = DlProgram.snapshot(root)

    results =
      1..4
      |> Task.async_stream(fn _ -> Program.prepare(toolchain(tmp), snapshot) end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, prepared} -> prepared end)

    [path] = results |> Enum.map(& &1.path) |> Enum.uniq()
    assert File.regular?(path)
    assert Path.wildcard(Path.join(toolchain(tmp).dir, "programs/*.tmp-*")) == []

    for prepared <- results do
      assert map_size(prepared.sources) == 2
      assert :erlang.band(File.stat!(prepared.path).mode, 0o222) == 0
      assert Enum.all?(Map.keys(prepared.sources), &File.regular?/1)
    end
  end

  test "captured authored identities retain active-declaration pruning", %{tmp_dir: tmp} do
    root = Path.join(tmp, "root.dl")
    declarations = Path.join(tmp, "schema.dl")

    File.write!(
      root,
      ".include \"schema.dl\"\n.decl out(x:symbol)\nout(x) :- kept(x).\n.output out\n"
    )

    File.write!(
      declarations,
      ".decl kept(x: symbol) mutable\n.input kept\n.decl unused(x: symbol) mutable\n.input unused\n"
    )

    first = DlProgram.snapshot(root)
    assert first.digest == DlProgram.program_digest(root)
    assert DlProgram.declared_digest(first, ["kept"]) == DlProgram.declared_digest(root, ["kept"])

    File.write!(
      declarations,
      String.replace(File.read!(declarations), "unused(x: symbol)", "unused(x: number)")
    )

    second = DlProgram.snapshot(root)
    refute first.digest == second.digest

    assert DlProgram.declared_digest(first, ["kept"]) ==
             DlProgram.declared_digest(second, ["kept"])

    refute DlProgram.declared_digest(first, :all) == DlProgram.declared_digest(second, :all)
  end

  describe "native tool and generic engine" do
    @describetag :flowlog
    @describetag timeout: 300_000

    test "inspect and generic serve use the installed linked closure and observe an edit", %{
      tmp_dir: tmp
    } do
      {root, leaf} = linked_program!(tmp)
      facts = Path.join(tmp, "facts")
      File.mkdir!(facts)
      File.write!(Path.join(facts, "input.facts"), "first\nsecond\n")
      {:ok, toolchain} = FlowLog.toolchain(progress: false)
      prepared = Program.prepare(toolchain, root)
      assert {:ok, manifest} = Program.inspect(toolchain, prepared)
      assert Enum.map(manifest.outputs, & &1.name) == ["out"]
      assert {:ok, built} = FlowLog.engine(root, engine: :generic, progress: false)
      assert ["serve", "--program", prepared_path | _] = built.args
      assert prepared_path == prepared.path
      assert built.digest == FlowLog.program_digest(root, ["input"])

      assert {:ok, %{"out" => [["first"]]}} =
               FlowLog.run(facts, root, engine: :generic, workers: 1, progress: false)

      File.write!(leaf, ".decl out(x:symbol)\nout(x) :- input(x), x = \"second\".\n.output out\n")

      assert {:ok, %{"out" => [["second"]]}} =
               FlowLog.run(facts, root, engine: :generic, workers: 1, progress: false)
    end

    test "diamond aliases solve once and a cycle remains a native cycle error", %{tmp_dir: tmp} do
      root = Path.join(tmp, "root.dl")
      leaf = Path.join(tmp, "leaf.dl")

      File.write!(
        root,
        ".decl input(x:symbol) mutable\n.input input\n.include \"left.dl\"\n.include \"right.dl\"\n"
      )

      File.write!(leaf, ".decl out(x:symbol)\nout(x) :- input(x).\n.output out\n")
      File.ln_s!("leaf.dl", Path.join(tmp, "alias.dl"))
      File.write!(Path.join(tmp, "left.dl"), ".include \"leaf.dl\"\n")
      File.write!(Path.join(tmp, "right.dl"), ".include \"alias.dl\"\n")
      facts = Path.join(tmp, "facts")
      File.mkdir!(facts)
      File.write!(Path.join(facts, "input.facts"), "one\n")

      assert {:ok, %{"out" => [["one"]]}} =
               FlowLog.run(facts, root, engine: :generic, workers: 1, progress: false)

      File.write!(leaf, ".include \"root.dl\"\n")
      assert {:error, {:flowlog_program, ^root, diagnostic}} = FlowLog.manifest(root)
      assert String.downcase(diagnostic) =~ "circular"
      refute diagnostic =~ "/programs/"
    end

    test "missing and invalid included sources report their authored path and original line", %{
      tmp_dir: tmp
    } do
      root = Path.join(tmp, "root.dl")
      leaf = Path.join(tmp, "leaf.dl")
      File.write!(root, ".decl input(x:symbol) mutable\n.input input\n.include \"leaf.dl\"\n")
      assert {:error, {:flowlog_program, ^root, missing}} = FlowLog.manifest(root)
      assert missing =~ leaf
      assert missing =~ "root.dl:3"
      refute missing =~ "/programs/"

      File.write!(
        leaf,
        "// original line 1\n// original line 2\n.decl out(x:symbol)\nout(x) :- absent(x).\n.output out\n"
      )

      assert {:error, {:flowlog_program, ^root, invalid}} = FlowLog.manifest(root)
      {:ok, toolchain} = FlowLog.toolchain(progress: false)
      {baseline, 1} = System.cmd(Toolchain.tool(toolchain), ["inspect", root])
      assert :json.decode(baseline)["diagnostic"] == invalid
      assert invalid =~ "root.dl:6"
      assert invalid =~ "absent"
      refute invalid =~ "/programs/"
    end
  end

  defp line_count(text), do: length(String.split(text, "\n"))

  defp toolchain(tmp) do
    %Toolchain{
      dir: Path.join(tmp, "toolchain"),
      key: "test",
      kind: :prebuilt,
      cargo: nil,
      rustc: nil,
      rustc_version: nil
    }
  end

  defp linked_program!(tmp) do
    priv = Path.join(tmp, "addon-checkout/priv")
    other = Path.join(tmp, "native/checkout/priv")
    wrong = Path.join(tmp, "two/priv")
    installed = Path.join(tmp, "build/lib/one")
    sibling = Path.join(tmp, "build/lib/two")
    for directory <- [priv, other, wrong, installed, sibling], do: File.mkdir_p!(directory)
    File.ln_s!(priv, Path.join(installed, "priv"))
    File.ln_s!(other, Path.join(sibling, "priv"))

    File.write!(
      Path.join(wrong, "rule.dl"),
      ".decl out(x:symbol)\nout(x) :- input(x), x = \"wrong-physical-target\".\n.output out\n"
    )

    leaf = Path.join(other, "rule.dl")
    File.write!(leaf, ".decl out(x:symbol)\nout(x) :- input(x), x = \"first\".\n.output out\n")
    root = Path.join(installed, "priv/root.dl")

    File.write!(
      root,
      ".decl input(x:symbol) mutable\n.input input\n.include \"../../two/priv/rule.dl\"\n"
    )

    {root, leaf}
  end
end
