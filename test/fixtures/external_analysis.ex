defmodule Argus.Test.ExternalProducer do
  @moduledoc false
  @behaviour Argus.Extractor

  @impl true
  def relations, do: [:external_value, :external_dependency_link, :external_role]
  @impl true
  def requirements, do: [:beam, :typed]
  @impl true
  def extract(data) do
    <<"FOR1", _::binary>> = data.beam
    [_ | _] = Map.fetch!(data.typed, :function_def)
    {:ok, {module, chunks}} = :beam_lib.chunks(data.beam, [:attributes])
    attributes = Keyword.fetch!(chunks, :attributes)

    if Keyword.get(attributes, :external_fail) == [true],
      do: raise("fixture producer failed")

    value = Keyword.get(attributes, :external_value, [])

    %{
      external_value: Enum.map(value, &[inspect(module), Atom.to_string(&1)]),
      external_dependency_link:
        if(module == :external_owner,
          do: [[inspect(module), inspect(:external_dependency)]],
          else: []
        ),
      external_role: [[inspect(module), to_string(Map.fetch!(data, :project?))]]
    }
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

defmodule Argus.Test.ExternalByteProducer do
  @moduledoc false
  @behaviour Argus.Extractor

  @impl Argus.Extractor
  def relations, do: [:external_beam_digest]

  @impl Argus.Extractor
  def requirements, do: [:beam]

  @impl Argus.Extractor
  def extract(data) do
    %{
      external_beam_digest: [
        [inspect(data.module), Argus.Test.ExternalByteProducer.digest(data.beam)]
      ]
    }
  end

  @spec digest(bytes :: binary()) :: String.t()
  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
