defmodule Argus.Dl.Program do
  @moduledoc """
  A Datalog program as a solve reads it: its files (the program and
  every file it `.include`s, transitively, resolved as FlowLog resolves
  an include, relative to the including file), and digests of them
  that name what decides a solve's outputs.

  `declared_digest/2` counts a file of declarations alone (argus's
  generated `base.dl`, `layer2.dl`, `priors.dl`) only by the
  declarations of the relations the program loads: FlowLog prunes an
  input no rule that reaches an output reads before it plans anything,
  so a relation added to the schema, or another relation's prose,
  moves no program's digest, and builds no engine again. The query graph
  keys each program on it (`Argus.Graph.Programs`, `Argus.FlowLog.program_digest/2`).
  """

  @type include_edge :: %{
          spelled: String.t(),
          path: Path.t(),
          identity: Path.t(),
          offset: non_neg_integer(),
          length: non_neg_integer()
        }
  @type source_file :: %{
          spelled: String.t(),
          path: Path.t(),
          identity: Path.t(),
          content: binary() | nil,
          includes: [include_edge()]
        }
  @type snapshot :: %{original: Path.t(), files: [source_file()], digest: binary()}

  # How long `stamped/2` trusts its files without a look, and the size
  # below which it looks at their content, not only their stat.
  @restat_ms 1_000
  @content_stamp 1_000_000

  @doc """
  A digest of a Datalog program: its own source and every file it
  includes, transitively, resolved the way FlowLog resolves an include
  (relative to the including file). Each file is named as the program
  spells it, so the digest is the same wherever the tree is checked out.
  """
  @spec program_digest(Path.t()) :: binary()
  def program_digest(rules_path) do
    path = Path.expand(rules_path)

    if shipped?(path) do
      stamped({__MODULE__, :program_digest, path}, fn -> compute_program_digest(path) end)
    else
      path |> compute_program_digest() |> elem(1)
    end
  end

  # A program argus ships is read at most once a second (`stamped/2`):
  # every solve of every corpus checkout asks. One anywhere else — a
  # test's, a caller's own — is read on every call, so an edit is seen
  # at once.
  defp shipped?(path), do: String.starts_with?(path, Argus.Dl.shipped() <> "/")

  defp compute_program_digest(path) do
    snapshot = snapshot(path)
    # Preserve the authored digest API's missing-file failure. Tool preparation
    # leaves missing edges for FlowLog to diagnose against the including line.
    for file <- snapshot.files, file.content == nil, do: Argus.RawFile.read!(file.path)
    {Enum.map(snapshot.files, & &1.path), snapshot.digest}
  end

  @doc """
  A digest of a Datalog program as a solve loading `relations` reads it
  (`:all`: as any solve of it does): its own source and every file it
  includes, transitively, as `program_digest/1` names them — except
  that a file of declarations alone, as `mix argus.gen.dl` writes them
  (`declarations/1`), counts only by the declarations of `relations`,
  in order, and not by its comments.

  FlowLog prunes an input relation no rule that reaches an output
  reads, before it plans anything: a declaration it prunes decides
  nothing a solve writes, and no line of the engine built for it. A
  declaration that no longer compiles beside the rest (a pruned rule
  that joins a relation whose type changed, a name that is now declared
  twice) fails the program, and that is caught before a solve is keyed:
  the relations it loads are resolved again (`Argus.FlowLog.manifest/2`)
  under `relations = :all`, which every declaration moves. `Argus.Graph.Identity.DeclaredDigestTest`
  changes every declaration a shipped program does not load and
  checks that its outputs, byte for byte, and this digest do not move.
  """
  @spec declared_digest(rules_path :: Path.t() | snapshot(), relations :: [String.t()] | :all) ::
          binary()
  def declared_digest(rules_path, relations) do
    parts =
      case rules_path do
        %{files: files} ->
          parts(files)

        path ->
          path = Path.expand(path)

          if shipped?(path) do
            stamped({__MODULE__, :program_parts, path}, fn -> program_parts(path) end)
          else
            path |> program_parts() |> elem(1)
          end
      end

    keep = if relations == :all, do: :all, else: MapSet.new(relations)

    parts
    |> Enum.reduce(:crypto.hash_init(:sha256), fn
      {:text, spelled, digest}, hash ->
        hash_parts(hash, ["text", spelled, digest])

      {:declarations, spelled, blocks}, hash ->
        kept =
          for {relation, block} <- blocks,
              keep == :all or MapSet.member?(keep, relation),
              part <- [relation, block],
              do: part

        hash_parts(hash, ["declarations", spelled, Integer.to_string(length(kept)) | kept])
    end)
    |> :crypto.hash_final()
  end

  defp hash_parts(hash, parts) do
    Enum.reduce(parts, hash, fn part, hash ->
      :crypto.hash_update(hash, <<byte_size(part)::64>> <> part)
    end)
  end

  # Each file of the program, in `program_files/1`'s order: a file of
  # declarations alone as its declarations, any other by its content.
  defp program_parts(path) do
    snapshot = snapshot(path)
    {Enum.map(snapshot.files, & &1.path), parts(snapshot.files)}
  end

  defp parts(files) do
    Enum.map(files, fn %{spelled: spelled, content: captured, path: path} ->
      content = if captured == nil, do: Argus.RawFile.read!(path), else: captured

      case declarations(content) do
        {:ok, blocks} -> {:declarations, spelled, blocks}
        :error -> {:text, spelled, :crypto.hash(:sha256, uncommented(content))}
      end
    end)
  end

  @doc ~S"""
  A program file's text as a solve reads it: without the lines that are
  a line comment alone (after any indentation), and without blank lines
  — what an edit to a rule's prose touches. FlowLog skips every such
  line, so a solve of the file writes what a solve of its text as given
  writes.

  A file holding a backslash at the end of a line, or the trigraph for
  one, is kept as given: it is not a program FlowLog reads differently,
  but a key over it may as well be conservative. A comment line that
  opens or closes a block comment is kept.

      iex> Argus.Dl.Program.uncommented("a(1).\n// why\n\n  // indented\nb(2).\n")
      "a(1).\nb(2)."

      iex> Argus.Dl.Program.uncommented("a(1). \\\n// spliced\nb(2).")
      "a(1). \\\n// spliced\nb(2)."
  """
  @spec uncommented(String.t()) :: String.t()
  def uncommented(content) do
    if String.contains?(content, ["\\\n", "\\\r", "??/"]) do
      content
    else
      content
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == "" or dropped_comment?(&1)))
      |> Enum.join("\n")
    end
  end

  defp dropped_comment?(line) do
    case String.trim_leading(line) do
      "//" <> comment -> not String.contains?(comment, ["/*", "*/"])
      _code -> false
    end
  end

  @doc """
  The declarations of a file that holds nothing else, as
  `mix argus.gen.dl` writes one: `{:ok, [{relation, lines}]}`, each
  relation's `.decl` and `.input` lines in order, or `:error` for any
  other file.

  A line is blank, a line comment, `.decl name(field: type, ...)` or
  `.input name` right after its own `.decl` — and nothing else, not an
  attribute or another comment: anything this does not read is text a
  key holds whole. The `mutable` qualifier `mix argus.gen.dl` gives every
  fact relation is part of its declaration's line. A comment ending in a
  backslash (or the trigraph for one) is not read as a comment either.
  """
  @spec declarations(String.t()) :: {:ok, [{String.t(), String.t()}]} | :error
  def declarations(content) do
    content
    |> String.split("\n")
    |> Enum.reduce_while({[], nil}, fn line, {blocks, pending} ->
      case {declaration_line(line), pending} do
        {:blank, pending} ->
          {:cont, {blocks, pending}}

        {{:decl, relation}, nil} ->
          {:cont, {blocks, {relation, line}}}

        {{:input, relation}, {relation, decl}} ->
          {:cont, {[{relation, decl <> "\n" <> line} | blocks], nil}}

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {blocks, nil} -> {:ok, Enum.reverse(blocks)}
      _ -> :error
    end
  end

  defp declaration_line(""), do: :blank

  defp declaration_line("//" <> comment) do
    if String.ends_with?(comment, "\\") or String.contains?(comment, "??/"),
      do: :other,
      else: :blank
  end

  defp declaration_line(line) do
    cond do
      match =
          Regex.run(~r/^\.decl ([A-Za-z_][A-Za-z0-9_]*)\([A-Za-z0-9_:, ]*\)( mutable)?$/, line) ->
        {:decl, Enum.at(match, 1)}

      match = Regex.run(~r/^\.input ([A-Za-z_][A-Za-z0-9_]*)$/, line) ->
        {:input, Enum.at(match, 1)}

      true ->
        :other
    end
  end

  @doc """
  `compute`'s value, kept for the life of the VM under `key` while the
  files it was computed from are unchanged. `compute` returns the files
  it read and the value; a later call looks at those files again at
  most once a second (their stat, and a small one's content) and
  computes afresh when one moved. Reading and hashing a program's
  sources on every solve was most of a warm corpus run's system time,
  and a stat per file per call still cost a millisecond a file on a
  busy disk.
  """
  @spec stamped(term(), (-> {[Path.t()], value})) :: value when value: term()
  def stamped(key, compute) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {files, stamps, value, checked} ->
        cond do
          now - :atomics.get(checked, 1) < @restat_ms ->
            value

          stamps(files) == stamps ->
            :atomics.put(checked, 1, now)
            value

          true ->
            restamp(key, compute, now)
        end

      nil ->
        restamp(key, compute, now)
    end
  end

  defp restamp(key, compute, now) do
    {files, value} = compute.()
    checked = :atomics.new(1, signed: true)
    :atomics.put(checked, 1, now)
    :persistent_term.put(key, {files, stamps(files), value, checked})
    value
  end

  # A small file (a Datalog source) by its content as well: a
  # modification time has a second's resolution, and an edit that keeps
  # the size inside that second is still an edit. A large one (the
  # solver) is replaced, not edited, which moves its inode or size.
  defp stamps(files) do
    Enum.map(files, fn file ->
      case Argus.RawFile.stat(file) do
        {:ok, %File.Stat{mtime: mtime, size: size, inode: inode}} when size <= @content_stamp ->
          {mtime, size, inode, content_stamp(file)}

        {:ok, %File.Stat{mtime: mtime, size: size, inode: inode}} ->
          {mtime, size, inode}

        {:error, reason} ->
          reason
      end
    end)
  end

  defp content_stamp(file) do
    case Argus.RawFile.read(file) do
      {:ok, content} -> :crypto.hash(:sha256, content)
      {:error, reason} -> reason
    end
  end

  @doc """
  The files of a Datalog program, `{spelling, path}` in the order they
  are first met: the program itself (spelled by its basename), then each
  `.include`d file (spelled as the include writes it), depth first.
  """
  @spec program_files(Path.t()) :: [{String.t(), Path.t()}]
  def program_files(rules_path) do
    Enum.map(snapshot(rules_path).files, &{&1.spelled, &1.path})
  end

  @doc "Capture original closure bytes and include edges once, before preparing a tool input."
  @spec snapshot(rules_path :: Path.t()) :: snapshot()
  def snapshot(rules_path) do
    path = Path.expand(rules_path)

    if shipped?(path) do
      stamped({__MODULE__, :snapshot, path}, fn ->
        captured = capture_snapshot(path)
        {Enum.map(captured.files, & &1.path), captured}
      end)
    else
      capture_snapshot(path)
    end
  end

  defp capture_snapshot(path) do
    {files, _seen} = capture(Path.basename(path), path, %{}, [])
    files = Enum.reverse(files)

    digest =
      Enum.reduce(files, :crypto.hash_init(:sha256), fn file, hash ->
        content = file.content || :erlang.term_to_binary({:missing, file.path})

        hash
        |> :crypto.hash_update(<<byte_size(file.spelled)::32>> <> file.spelled)
        |> :crypto.hash_update(<<byte_size(content)::64>> <> content)
      end)
      |> :crypto.hash_final()

    %{original: path, files: files, digest: digest}
  end

  defp capture(spelled, path, seen, files) do
    identity = physical(path)

    if Map.has_key?(seen, identity) do
      {files, seen}
    else
      content =
        case Argus.RawFile.read(path) do
          {:ok, bytes} -> bytes
          {:error, _} -> nil
        end

      includes = if content, do: includes(content, path), else: []

      file = %{
        spelled: spelled,
        path: path,
        identity: identity,
        content: content,
        includes: includes
      }

      Enum.reduce(includes, {[file | files], Map.put(seen, identity, true)}, fn edge,
                                                                                {files, seen} ->
        capture(edge.spelled, edge.path, seen, files)
      end)
    end
  end

  # Retain the include resolver's spelling/order. A prepared graph changes only
  # the quoted target bytes; the directive and every newline stay in place.
  defp includes(content, path) do
    Regex.scan(~r/^\s*[.#]include\s+"([^"]+)"/m, content, return: :index)
    |> Enum.map(fn [_whole, {offset, length}] ->
      spelled = binary_part(content, offset, length)
      target = Path.expand(spelled, Path.dirname(path))

      %{
        spelled: spelled,
        path: target,
        identity: physical(target),
        offset: offset,
        length: length
      }
    end)
  end

  defp absolute(path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(File.cwd!(), path)
  end

  # Targets were expanded lexically by the authored include resolver above.
  # Canonicalize aliases only after that decision, to retain native same-file
  # diamond/cycle behavior without changing which installed sibling is named.
  defp physical(path), do: physical(Path.split(absolute(path)), "/", 0)
  defp physical([], resolved, _links), do: resolved
  defp physical(["/" | rest], _resolved, links), do: physical(rest, "/", links)
  defp physical(["." | rest], resolved, links), do: physical(rest, resolved, links)
  defp physical([".." | rest], resolved, links), do: physical(rest, Path.dirname(resolved), links)

  defp physical([part | rest], resolved, links) do
    candidate = Path.join(resolved, part)

    case File.read_link(candidate) do
      {:ok, target} when links < 40 ->
        target = if Path.type(target) == :absolute, do: target, else: Path.join(resolved, target)
        physical(Path.split(target) ++ rest, "/", links + 1)

      {:ok, _} ->
        raise File.Error, reason: :eloop, action: "resolve include", path: candidate

      {:error, _} ->
        physical(rest, candidate, links)
    end
  end
end
