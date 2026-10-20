defmodule Argus.Driver.PreparationTest do
  use ExUnit.Case, async: true

  alias Argus.Driver.Preparation
  alias Argus.Graph
  alias Roux.{Blob, Input, Memo, QueryLog, Runtime}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "checkpoints preserve facts, full membership and warm validation", %{tmp_dir: dir} do
    paths = fixtures(dir)
    first = run(dir, paths, 1)
    assert first.changed
    assert first.errors == []
    assert first.inner_count == 0
    warm = run(dir, paths, 1)
    refute warm.changed
    assert warm.packs == first.packs
    assert warm.inner_count == 0

    independent = run(Path.join(dir, "independent"), paths, 64)
    assert independent.packs == first.packs
  end

  test "unchanged module packs validate without replaying extraction traces", %{tmp_dir: dir} do
    paths = fixtures(dir)
    first = run(dir, paths, 1)
    log = QueryLog.start(:all)

    try do
      warm = run(dir, paths, 1)
      assert warm.packs == first.packs
      refute warm.changed

      for query <- [:module_facts, :module_in_process] do
        assert Enum.filter(QueryLog.executions(log, query), &(&1 in paths)) == []

        assert Enum.sort(Enum.filter(QueryLog.hits(log, query), &(&1 in paths))) ==
                 Enum.sort(paths)
      end
    after
      QueryLog.stop(log)
    end
  end

  test "a changed beam and its revert survive session checkpoints", %{tmp_dir: dir} do
    paths = fixtures(dir)
    first = run(dir, paths, 1)
    [path | _] = paths
    original = File.read!(path)
    beam!(path, :preparation_fixture_1, 99)
    changed = run(dir, paths, 1)
    assert changed.changed
    refute changed.packs == first.packs
    File.write!(path, original)
    reverted = run(dir, paths, 1)
    assert reverted.changed
    assert reverted.packs == first.packs
    refute run(dir, paths, 1).changed
  end

  test "force remains effective and a missing pack blob rebuilds", %{tmp_dir: dir} do
    paths = fixtures(dir)
    first = run(dir, paths, 1)
    store = Blob.open!(Path.join(dir, "store"))
    {_key, {:ok, pack}} = hd(first.packs)
    File.rm!(Blob.path(store, pack.pack))
    assert run(dir, paths, 1).packs == first.packs
    forced = run(dir, paths, 1, force: true)
    assert forced.changed
    assert forced.packs == first.packs
  end

  test "temporary stores survive rotation and are destroyed after success or failure", %{
    tmp_dir: dir
  } do
    paths = fixtures(dir)

    for failure <- [false, true] do
      store = Blob.temporary()
      options = [store: store, preparation_batch_size: 1]
      initialize = initializer(paths)

      finish = fn session, _state, _changed, _errors ->
        assert File.dir?(store.root)
        assert Enum.all?(paths, &match?({:ok, _}, Runtime.query(session.db, :module_facts, &1)))
        if failure, do: raise("fixture finish failure"), else: :finished
      end

      if failure do
        assert_raise RuntimeError, "fixture finish failure", fn ->
          Preparation.run(options, initialize, finish)
        end
      else
        assert :finished = Preparation.run(options, initialize, finish)
      end

      refute File.exists?(store.root)
    end
  end

  test "a failed initializer closes the session and removes its temporary store" do
    store = Blob.temporary()

    assert_raise RuntimeError, "fixture initialization failure", fn ->
      Preparation.run([store: store], fn _ -> raise "fixture initialization failure" end, fn _,
                                                                                             _,
                                                                                             _,
                                                                                             _ ->
        flunk("finish must not run")
      end)
    end

    refute File.exists?(store.root)
  end

  test "manifest-less runs isolate their scratch manifests in a shared persistent store", %{
    tmp_dir: dir
  } do
    paths = fixtures(dir)
    store = Blob.open!(Path.join(dir, "shared-store"))
    owner = self()

    tasks =
      for marker <- [:first, :second] do
        Task.async(fn ->
          initialize = fn session ->
            state = initializer(paths).(session)
            Input.set(session.db, :program, :marker, marker)
            send(owner, {:ready, marker, session.manifest, self()})
            receive do: (:proceed -> state)
          end

          Preparation.run([store: store, preparation_batch_size: 1], initialize, fn session,
                                                                                    state,
                                                                                    _changed,
                                                                                    _errors ->
            assert Input.get(session.db, :program, :marker) == marker
            assert Input.get(session.db, :program, :project) == paths
            Roux.Session.commit(session, state.meta)
            assert File.regular?(session.manifest)

            assert Path.dirname(Path.dirname(session.manifest)) ==
                     Path.join(store.root, "scratch")

            session.manifest
          end)
        end)
      end

    assert_receive {:ready, :first, first, first_pid}, 10_000
    assert_receive {:ready, :second, second, second_pid}, 10_000
    refute first == second
    send(first_pid, :proceed)
    send(second_pid, :proceed)
    Enum.each(tasks, &Task.await(&1, 30_000))
    refute File.exists?(Path.dirname(first))
    refute File.exists?(Path.dirname(second))
    assert File.dir?(store.root)

    assert_raise RuntimeError, "persistent-store finish failed", fn ->
      Preparation.run([store: store, preparation_batch_size: 1], initializer(paths), fn _,
                                                                                        _,
                                                                                        _,
                                                                                        _ ->
        raise "persistent-store finish failed"
      end)
    end

    assert File.ls!(Path.join(store.root, "scratch")) == []
  end

  test "unreadable modules retain their extraction notices across checkpoints", %{tmp_dir: dir} do
    paths = fixtures(dir)
    [bad | _] = paths
    File.write!(bad, "not a BEAM file")
    result = run(dir, paths, 1)
    assert Enum.any?(result.errors, &(&1.source == bad and &1.step == "module"))
    assert Enum.uniq(result.errors) == result.errors
  end

  defp run(dir, paths, size, extra \\ []) do
    options =
      [
        store: Path.join(dir, "store"),
        manifest: Path.join(dir, "manifest"),
        preparation_batch_size: size
      ] ++ extra

    Preparation.run(options, initializer(paths), fn session, state, changed, errors ->
      assert Input.get(session.db, :program, :project) == paths

      packs =
        for path <- paths,
            query <- [:module_facts, :module_in_process],
            do: {{query, path}, Runtime.query(session.db, query, path)}

      inner_count =
        Enum.count(
          paths,
          &match?({:ok, _}, Memo.get(session.db, {:extraction_pack, {&1, :extracted}}))
        )

      Roux.Session.commit(session, state.meta)
      %{packs: packs, changed: changed, errors: errors, inner_count: inner_count}
    end)
  end

  defp initializer(paths) do
    fn session ->
      %{meta: meta} =
        Roux.Sources.sync(session.db, :beam, Map.new(paths, &{&1, &1}), session.sources,
          hash: &Blob.digest/1,
          value: fn %{hash: hash} -> %{hash: hash} end
        )

      Input.set(session.db, :program, :project, paths)
      Graph.set_environment(session.db, analyses: [:coupling], stamps: false)
      %{keys: paths, meta: meta}
    end
  end

  defp fixtures(dir) do
    File.mkdir_p!(dir)

    for number <- 1..3 do
      path = Path.join(dir, "fixture#{number}.beam")
      beam!(path, String.to_atom("preparation_fixture_#{number}"), number)
      path
    end
  end

  defp beam!(path, module, value) do
    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 2, :export, [value: 0]},
      {:function, 3, :value, 0, [{:clause, 3, [], [], [{:integer, 3, value}]}]}
    ]

    {:ok, ^module, bytes} = :compile.forms(forms, [:binary, :debug_info])
    File.write!(path, bytes)
  end
end

defmodule Argus.Driver.PreparationTimeoutTest do
  # The timeout is process-global application configuration.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "lost packs remain visible when a post-checkpoint retry succeeds", %{tmp_dir: dir} do
    [{_, bytes}] =
      Code.compile_string("defmodule PreparationTimeoutFixture do\n def value, do: 1\nend")

    key = :timeout_fixture
    prior = Application.fetch_env(:argus_beam, :extraction_timeout)

    try do
      Application.put_env(:argus_beam, :extraction_timeout, 0)

      initialize = fn session ->
        Roux.Input.set(session.db, :beam, key, %{data: bytes, hash: Roux.Blob.digest(bytes)})
        Roux.Input.set(session.db, :program, :project, [key])
        Argus.Graph.set_environment(session.db, analyses: [:coupling], stamps: false)
        %{keys: [key], meta: %{}}
      end

      Argus.Driver.Preparation.run(
        [
          store: Path.join(dir, "store"),
          manifest: Path.join(dir, "manifest"),
          preparation_batch_size: 1
        ],
        initialize,
        fn session, _state, changed, errors ->
          assert changed
          assert Enum.any?(errors, &(&1.reason =~ "extraction did not finish within 0 ms"))
          Application.delete_env(:argus_beam, :extraction_timeout)
          assert {:ok, %{lost: false}} = Roux.Runtime.query(session.db, :module_facts, key)
        end
      )
    after
      case prior do
        {:ok, value} -> Application.put_env(:argus_beam, :extraction_timeout, value)
        :error -> Application.delete_env(:argus_beam, :extraction_timeout)
      end
    end
  end
end
