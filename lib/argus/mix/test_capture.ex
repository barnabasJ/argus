defmodule Argus.Mix.TestCapture do
  @moduledoc false

  alias Argus.Project.Mix, as: MixProject

  @capture {__MODULE__, :directory}

  @doc "Compile selected tests through Mix's dry run and analyze the captured modules."
  @spec run(test_args :: [String.t()], analyze :: (Argus.Project.t() -> result)) :: result
        when result: term()
  def run(test_args, analyze) do
    if :persistent_term.get(@capture, nil) do
      Mix.raise("argus.test capture is already active in this VM")
    end

    require_fresh_tests!()
    MixProject.compile!(test_args -- ["--warnings-as-errors"])

    directory =
      Path.join(
        Mix.Project.manifest_path(),
        "argus-test-capture-#{:os.getpid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Mix.Project.manifest_path())
    File.mkdir!(directory)
    compiler_options = Code.compiler_options()
    original_test_options = Mix.Project.config()[:test_elixirc_options]
    original_prune_code_paths = Keyword.get(Mix.Project.config(), :prune_code_paths, true)
    test_options = original_test_options || []

    tracers =
      Enum.uniq([
        __MODULE__ | Keyword.get(test_options, :tracers, []) ++ compiler_options.tracers
      ])

    :persistent_term.put(@capture, directory)

    try do
      Code.compiler_options(
        tracers: Enum.uniq([__MODULE__ | compiler_options.tracers]),
        debug_info: true
      )

      Mix.ProjectStack.merge_config(
        test_elixirc_options: Keyword.merge(test_options, tracers: tracers, debug_info: true),
        prune_code_paths: false
      )

      Mix.Task.rerun("test", test_args ++ ["--dry-run"])
      project = MixProject.current()
      app = Mix.Project.config()[:app]

      analyze.(%{
        project
        | apps: [{app, directory} | project.apps],
          state_dir: Path.join(project.state_dir, "argus-tests")
      })
    after
      :persistent_term.erase(@capture)
      Code.compiler_options(compiler_options)

      Mix.ProjectStack.merge_config(
        test_elixirc_options: original_test_options,
        prune_code_paths: original_prune_code_paths
      )

      File.rm_rf!(directory)
    end
  end

  defp require_fresh_tests! do
    paths = Enum.map(Mix.Project.config()[:test_paths] || ["test"], &Path.expand/1)

    loaded =
      Enum.find(Code.required_files(), fn file ->
        Enum.any?(paths, &(file == &1 or String.starts_with?(file, &1 <> "/")))
      end)

    if loaded do
      Mix.raise(
        "argus.test requires a fresh Mix VM; #{Path.relative_to_cwd(loaded)} was already required. " <>
          "Run mix argus.test as a separate command, not after mix test or mix run in the same VM."
      )
    end
  end

  @doc false
  @spec trace(event :: term(), environment :: Macro.Env.t()) :: :ok
  def trace({:on_module, bytecode, _}, %{module: module}) do
    directory = :persistent_term.get(@capture, nil)

    if directory do
      target = Path.join(directory, Atom.to_string(module) <> ".beam")
      temporary = target <> ".#{System.unique_integer([:positive])}.tmp"
      File.write!(temporary, bytecode, [:exclusive])
      File.rename!(temporary, target)
    end

    :ok
  end

  def trace(_event, _environment), do: :ok
end
