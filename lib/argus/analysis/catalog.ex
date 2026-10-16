defmodule Argus.Analysis.Catalog do
  @moduledoc """
  The built-in analyses: which modules implement `Argus.Analysis`, how
  to find one by name, what it declares, and where its rules live.

  Discovery reads the `:argus_beam` application's module list, keeping the
  modules that export the behaviour's required callbacks, sorted by
  name. Discovery is cached once per VM; the application's module list is
  fixed when it loads. Relation definitions are read through their accessors.

  `Argus.Analysis` delegates its lookup functions here
  (`builtin_analyses/0`, `fetch_module/1`, `output_relations/1`, ...);
  callers use those.
  """

  alias Argus.Analysis

  @doc "The names of the built-in analyses, sorted."
  @spec names() :: [atom()]
  def names, do: Enum.map(modules(), & &1.name())

  @doc """
  The built-in analysis modules, sorted by name. Found once per VM among
  the application's modules named `Argus.Analyses.<Name>`, and kept: the
  application's module list is fixed when it loads. Only those are
  loaded to be asked: loading every module the application holds (all
  of argus, and in the test build its thousands of fixtures) was most of
  what a fresh VM spent before its first query.
  """
  @spec modules() :: [module()]
  def modules do
    case :persistent_term.get({__MODULE__, :modules}, nil) do
      nil ->
        modules =
          argus_modules()
          |> Enum.filter(fn mod ->
            analysis_name?(mod) and Code.ensure_loaded?(mod) and
              function_exported?(mod, :name, 0) and
              function_exported?(mod, :rules_file, 0) and
              function_exported?(mod, :output_relations, 0)
          end)
          |> Enum.sort_by(& &1.name())

        :persistent_term.put({__MODULE__, :modules}, modules)
        modules

      modules ->
        modules
    end
  end

  @doc "The built-in analysis module named `name`: `{:ok, module}` or `:error`."
  @spec fetch(atom()) :: {:ok, module()} | :error
  def fetch({:custom, _path}), do: :error

  def fetch({module, options}) when is_atom(module) and is_list(options), do: fetch(module)

  def fetch(name) when is_atom(name) do
    case fetch_builtin(name) do
      {:ok, _} = found -> found
      :error -> if external?(name), do: {:ok, name}, else: :error
    end
  end

  def fetch(_selection), do: :error

  defp fetch_builtin(name) do
    case Enum.find(modules(), &(&1.name() == name)) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  @doc "Whether an explicitly supplied module implements the analysis contract."
  @spec external?(term()) :: boolean()
  def external?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?([name: 0, rules_file: 0, extractors: 0, output_relations: 0], fn {name, arity} ->
        function_exported?(module, name, arity)
      end)
  end

  def external?(_), do: false

  @doc "The module and options of an explicit analysis selection."
  @spec selection(term()) :: {:ok, module(), keyword()} | :error
  def selection({module, options}) when is_list(options) do
    if external?(module) and Keyword.keyword?(options), do: {:ok, module, options}, else: :error
  end

  def selection(name) do
    case fetch(name) do
      {:ok, module} -> {:ok, module, []}
      :error -> :error
    end
  end

  @doc "The reporting name of a builtin or explicit analysis selection."
  @spec name(term()) :: atom()
  def name(selection) do
    case fetch(selection) do
      {:ok, module} -> module.name()
      :error -> selection
    end
  end

  @doc "The output relations a built-in analysis declares: `{:ok, relations}` or `:error`."
  @spec output_relations(atom()) :: {:ok, [Analysis.output_relation()]} | :error
  def output_relations(name) do
    case fetch(name) do
      {:ok, mod} -> {:ok, mod.output_relations()}
      :error -> :error
    end
  end

  @doc """
  The output relations of an analysis whose rows are findings: every
  output relation but the evidence ones and the one that re-tiers them
  (`retier: :tooling`).
  """
  @spec finding_relations(atom()) :: {:ok, [Analysis.output_relation()]} | :error
  def finding_relations(name) do
    with {:ok, relations} <- output_relations(name) do
      {:ok, Enum.reject(relations, &(Map.has_key?(&1, :evidence) or Map.has_key?(&1, :retier)))}
    end
  end

  @doc """
  The FlowLog program an analysis runs: a built-in's `rules_file/0`
  under `priv/dl/`, or a custom program's own path. Either must exist.
  """
  @spec rules_path(Analysis.analysis()) :: {:ok, Path.t()} | {:error, term()}
  def rules_path({:custom, path}) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, {:rules_not_found, path}}
    end
  end

  def rules_path({module, options}) when is_list(options), do: rules_path(module)

  def rules_path(name) when is_atom(name) do
    case fetch(name) do
      {:ok, mod} ->
        path =
          if name not in names() do
            declared = mod.rules_file()

            if Path.type(declared) == :absolute do
              declared
            else
              case :code.which(mod) do
                beam when is_list(beam) ->
                  root = beam |> to_string() |> Path.dirname() |> Path.dirname()
                  Path.join([root, "priv/dl", declared])

                _ ->
                  declared
              end
            end
          else
            Argus.Dl.path(mod.rules_file())
          end

        if File.exists?(path, [:raw]) do
          {:ok, path}
        else
          {:error, {:rules_not_found, path}}
        end

      :error ->
        {:error, {:unknown_analysis, name}}
    end
  end

  defp analysis_name?(mod) do
    case Atom.to_string(mod) do
      "Elixir.Argus.Analyses." <> name -> not String.contains?(name, ".")
      _ -> false
    end
  end

  # The :modules key only exists once the application is *loaded* — which
  # plain code-path embedding (escripts, sandbox VMs that only call
  # :code.add_paths/1) never does. Loading is cheap, idempotent, and does
  # not start anything, so do it on demand rather than crash.
  defp argus_modules do
    case :application.get_key(:argus_beam, :modules) do
      {:ok, modules} ->
        modules

      :undefined ->
        case :application.load(:argus_beam) do
          ok when ok in [:ok, {:error, {:already_loaded, :argus_beam}}] ->
            :ok

          {:error, reason} ->
            raise "could not load the :argus_beam application: #{inspect(reason)}"
        end

        {:ok, modules} = :application.get_key(:argus_beam, :modules)
        modules
    end
  end
end
