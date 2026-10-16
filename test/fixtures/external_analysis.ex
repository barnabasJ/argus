defmodule Argus.Test.ExternalProducer do
  @moduledoc false
  @behaviour Argus.Extractor

  @impl true
  def relations, do: [:external_value]
  @impl true
  def requirements, do: [:beam, :typed]
  @impl true
  def extract(data) do
    true = is_binary(data.beam)
    [_ | _] = Map.fetch!(data.typed, :function_def)

    value =
      case Argus.Extractor.Helpers.read_beam(:external_reference) do
        {:ok, bytes} ->
          {:ok, {:external_reference, chunks}} = :beam_lib.chunks(bytes, [:attributes])

          chunks
          |> Keyword.fetch!(:attributes)
          |> Keyword.fetch!(:external_value)
          |> hd()
          |> Atom.to_string()

        {:error, :enoent} ->
          "missing"
      end

    %{external_value: [[inspect(data.module), value]]}
  end
end

defmodule Argus.Test.ExternalAnalysis do
  @moduledoc false
  @behaviour Argus.Analysis
  @impl true
  def name, do: :external_analysis
  @impl true
  def description, do: "A native external analysis fixture"
  @impl true
  def rules_file, do: Path.expand("programs/external.dl", __DIR__)
  @impl true
  def extractors, do: [Argus.Test.ExternalProducer]
  @impl true
  def input_facts(options) do
    %{
      facts:
        Keyword.get_lazy(options, :facts, fn ->
          %{external_policy: [[Keyword.fetch!(options, :value)]]}
        end),
      schemas: [%{name: :unused_policy, fields: [{:value, :symbol, "unused declared policy"}]}]
    }
  end

  @impl true
  def output_relations do
    [
      %{
        name: :external_found,
        fields: [{:module, :symbol, "module"}, {:value, :symbol, "value"}],
        key: [:module],
        doc: "An extracted value matches explicit policy."
      }
    ]
  end

  @impl true
  def finding(:external_found, [module, value]) do
    Argus.Findings.new(:warning, "External value #{value}", "Native extractor and policy facts.",
      at: Argus.Findings.at_module(module)
    )
  end
end

defmodule Argus.Test.MissingExternalAnalysis do
  @moduledoc false
  @behaviour Argus.Analysis
  @impl true
  def name, do: :missing_external
  @impl true
  def description, do: "An unavailable external program fixture"
  @impl true
  def rules_file, do: Path.expand("programs/unavailable.dl", __DIR__)
  @impl true
  def extractors, do: []
  @impl true
  def output_relations, do: []
end

defmodule Argus.Test.ExternalDebugBackend do
  @moduledoc false
  def debug_info(_format, _module, {:probe, receiver}, _options) do
    send(receiver, :external_debug_backend_executed)
    {:error, :unsupported}
  end
end
