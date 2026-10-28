defmodule Argus.Test.ReviewedFrontend do
  @moduledoc "Real compiled fixture controls shared by the compiler and one-shot frontend suites."
  import ExUnit.Assertions
  import ExUnit.CaptureIO, only: [with_io: 1, with_io: 2]
  alias Argus.Test.Fixture

  @config [
    analyses: [:blocking],
    engine: :require,
    fail_on: :warning,
    reviewed_findings: "reviews.json"
  ]

  @doc "Create a unique normal Mix project with five real callers of one GenServer."
  @spec checkout!() :: {Path.t(), atom()}
  def checkout! do
    unique = System.unique_integer([:positive])
    app = String.to_atom("depot_reviewed_#{unique}")

    copy =
      Fixture.checkout!(Path.join(System.tmp_dir!(), "argus_reviews_#{unique}"), @config, app)

    for number <- 1..5 do
      File.write!(Path.join(copy, "lib/depot/review_caller_#{number}.ex"), """
      defmodule Depot.ReviewCaller#{number} do
        def ask, do: GenServer.call(Depot.Sonar, :ping)
      end
      """)
    end

    File.write!(Path.join(copy, "reviews.json"), "[]")
    {copy, app}
  end

  @doc "Compile actual source, then obtain records only from the native Driver's current run."
  @spec bootstrap!() :: {Argus.Driver.Result.t(), [map()]}
  def bootstrap! do
    assert {:error, diagnostics} = Fixture.compile!()
    assert Enum.any?(diagnostics, &(&1.compiler_name == "argus" and &1.severity == :warning))
    run = current!()

    assert Enum.any?(
             run.review.analyses.blocking.findings,
             &(&1.title == "High synchronous fan-in")
           )

    records = records(run)
    write_records(records)
    {run, records}
  end

  @doc "Read the actual current compiled project through the public Driver."
  @spec current!() :: Argus.Driver.Result.t()
  def current! do
    Argus.Driver.run(Argus.Config.load(), review_proof: true)
  end

  @doc "Data records for exact current fixture diagnostics; never a fabricated proof."
  @spec records(Argus.Driver.Result.t(), String.t() | nil) :: [map()]
  def records(run, except \\ nil) do
    for {_name, analysis} <- Enum.sort(run.review.analyses),
        finding <- analysis.findings,
        finding.title != except do
      finding.review_identity
      |> Argus.ReviewedFindings.candidate(run.review.proof)
      |> Map.merge(%{
        "decision" => "false_positive",
        "justification" => "Exact native fixture review."
      })
    end
  end

  @doc "Write JSON data only."
  @spec write_records([map()]) :: :ok
  def write_records(records), do: File.write!("reviews.json", JSON.encode!(records))

  @doc "Run the actual complete compiler chain or actual one-shot Mix task."
  @spec invoke(:compiler | :task) :: tuple()
  def invoke(:compiler), do: Fixture.compile_io!()

  def invoke(:task) do
    {{result, stdout}, stderr} =
      with_io(:stderr, fn ->
        with_io(fn ->
          Mix.Task.rerun("argus", [
            "--format",
            "json",
            "--fail-above",
            "0",
            "--fail-on",
            "warning"
          ])
        end)
      end)

    {result, stdout, stderr}
  end

  @doc "Exact reviews pass their native gates but remain visible."
  @spec assert_reviewed!(:compiler | :task) :: term()
  def assert_reviewed!(:compiler) do
    {{status, diagnostics}, output} = invoke(:compiler)
    assert status in [:ok, :noop]
    argus = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))
    assert argus != []
    assert Enum.all?(argus, &(&1.severity == :information))
    assert Enum.all?(argus, &(&1.details =~ "Exact native fixture review."))
    assert output =~ "Reviewed false_positive; original severity: warning"
    assert output =~ ~s(Justification: "Exact native fixture review.")
    assert output =~ "High synchronous fan-in"
    assert Mix.Tasks.Compile.Argus.diagnostics() == argus
  end

  def assert_reviewed!(:task) do
    assert {:ok, stdout, _stderr} = invoke(:task)
    entries = JSON.decode!(stdout)
    assert entries != []
    assert Enum.all?(entries, &(&1["review"]["status"] == "reviewed"))
    assert Enum.any?(entries, &(&1["severity"] == "warning"))
    assert Enum.all?(entries, &(&1["review"]["justification"] == "Exact native fixture review."))
  end

  @doc "A same-MFA new self-call remains an actual unreviewed error."
  @spec assert_new_error!(:compiler | :task) :: term()
  def assert_new_error!(:compiler) do
    assert {{:error, diagnostics}, _output} = invoke(:compiler)

    assert Enum.any?(
             diagnostics,
             &(&1.severity == :error and
                 &1.message =~ "Synchronous call to the calling process itself")
           )
  end

  def assert_new_error!(:task) do
    assert_raise Mix.Error, ~r/findings/, fn -> invoke(:task) end
  end

  @doc "Edit a real fixture source and advance its normal compile timestamp."
  @spec edit!(Path.t(), (String.t() -> String.t())) :: :ok
  def edit!(path, change) do
    original = File.read!(path)
    modified = change.(original)
    assert modified != original
    File.write!(path, modified)
    bump = Process.get({__MODULE__, :edit}, 0) + 1
    Process.put({__MODULE__, :edit}, bump)
    File.touch!(path, System.os_time(:second) + bump)
  end

  @doc "Recompile changed real source with zero accepted records, then observe its new native census."
  @spec changed!() :: Argus.Driver.Result.t()
  def changed! do
    write_records([])
    {_status, _diagnostics} = Fixture.compile!()
    current!()
  end
end
