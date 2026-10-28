defmodule Argus.ReviewedFindingsDriverTest do
  use ExUnit.Case, async: true

  alias Argus.{Project, ReviewedFindings}
  alias Argus.ReviewedFindings.Proof
  alias Argus.Test.Projects

  @moduletag :tmp_dir
  @moduletag :flowlog
  @moduletag timeout: 300_000

  test "real native driver findings and gates stay intact while proof is opt-in", %{tmp_dir: dir} do
    root = Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))
    {:ok, project} = Project.load(:rebar3, root)
    config = Argus.Config.load(analyses: [:coupling, :failure], engine: :require)
    ordinary = Argus.Driver.run(config, project: project)
    assert ordinary.review == nil
    observed = Argus.Driver.run(config, project: project, review_proof: true)
    assert observed.located == ordinary.located
    assert observed.notices == []
    assert observed.review.proof.complete?

    assert Proof.certificate_inventory(Proof.inventory!(project)) ==
             observed.review.proof.binding.inventory

    candidates =
      for {_name, analysis} <- observed.review.analyses,
          finding <- analysis.findings do
        ReviewedFindings.candidate(finding.review_identity, observed.review.proof)
      end

    assert candidates != []
    assert Enum.all?(ReviewedFindings.match!(candidates, []), &(&1.status == :unreviewed))
    # The actual existing failure gate sees every finding; this candidate does
    # not install a sidecar config or alter CLI/compile/escript thresholds.
    entries = Argus.Report.build(observed.located, config, root)
    assert Argus.CLI.failing(entries, :info) == entries
  end

  test "fresh native builds in different roots produce the same full certificate", %{tmp_dir: dir} do
    config = Argus.Config.load(analyses: [:coupling, :failure], engine: :require)

    proofs =
      for name <- ["first", "second"] do
        root = Projects.synthesize!(:rebar3_app, Path.join(dir, name))
        {:ok, project} = Project.load(:rebar3, root)
        Argus.Driver.run(config, project: project, review_proof: true).review.proof
      end

    [first, second] = proofs
    assert first.binding == second.binding
    assert first.digest == second.digest
  end

  test "application identity and role changes invalidate certificates even with the same content",
       %{tmp_dir: dir} do
    root = Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))
    {:ok, project} = Project.load(:rebar3, root)
    before = Proof.certificate_inventory(Proof.inventory!(project))
    [{app, ebin} | rest] = project.apps
    renamed = %{project | apps: [{:renamed_application, ebin} | rest]}
    refute Proof.certificate_inventory(Proof.inventory!(renamed)) == before
    rerolled = %{project | apps: rest, deps: [{app, ebin} | project.deps]}
    refute Proof.certificate_inventory(Proof.inventory!(rerolled)) == before
    duplicated = %{project | apps: [{app, ebin} | project.apps]}
    assert_raise ArgumentError, fn -> Proof.inventory!(duplicated) end
  end

  test "a real self-call defect in the reviewed MFA stays unreviewed", %{tmp_dir: dir} do
    root = Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))
    source_dir = Path.join(root, "apps/shop/src")
    ebin = Path.join(root, "_build/default/lib/shop/ebin")

    for number <- 1..5 do
      path = Path.join(source_dir, "review_caller_#{number}.erl")

      File.write!(path, """
      -module(review_caller_#{number}).
      -export([ask/0]).
      ask() -> gen_server:call(shop_sonar, ping).
      """)

      compile_source!(path, ebin)
    end

    {:ok, project} = Project.load(:rebar3, root)
    config = Argus.Config.load(analyses: [:blocking], engine: :require)
    original = Argus.Driver.run(config, project: project, review_proof: true)

    fan_in =
      Enum.find(
        original.review.analyses.blocking.findings,
        &(&1.title == "High synchronous fan-in")
      )

    assert fan_in.mfa == {:shop_sonar, :handle_call, 3}
    previous = ReviewedFindings.candidate(fan_in.review_identity, original.review.proof)

    record =
      Map.merge(previous, %{
        "decision" => "false_positive",
        "justification" => "Test review of this exact fan-in only."
      })

    path = Path.join(source_dir, "shop_sonar.erl")
    source = File.read!(path)

    modified =
      String.replace(
        source,
        "handle_call(ping, _From, State) ->",
        "handle_call(ping, _From, State) ->\n    gen_server:call(self(), ping),"
      )

    assert modified != source
    File.write!(path, modified)
    compile_source!(path, ebin)
    changed = Argus.Driver.run(config, project: project, review_proof: true)

    self_call =
      Enum.find(
        changed.review.analyses.blocking.findings,
        &(&1.title == "Synchronous call to the calling process itself")
      )

    assert self_call.mfa == fan_in.mfa
    assert self_call.severity == :error

    candidates =
      Enum.map(changed.review.analyses.blocking.findings, fn finding ->
        ReviewedFindings.candidate(finding.review_identity, changed.review.proof)
      end)

    assert_raise ArgumentError, ~r/stale review/, fn ->
      ReviewedFindings.match!(candidates, [record])
    end

    assert Enum.all?(ReviewedFindings.match!(candidates, []), &(&1.status == :unreviewed))
    entries = Argus.Report.build(changed.located, config, root)
    assert Enum.any?(Argus.CLI.failing(entries, :error), &(&1.title == self_call.title))
  end

  defp compile_source!(source, ebin) do
    options = [:debug_info, :return_errors, {:outdir, String.to_charlist(ebin)}]

    case :compile.file(String.to_charlist(source), options) do
      {:ok, _module} -> :ok
      {:ok, _module, _warnings} -> :ok
      other -> flunk("native Erlang fixture compilation failed: #{inspect(other)}")
    end
  end

  test "native input inventory binds dependency sources and fails when one disappears", %{
    tmp_dir: dir
  } do
    root = Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))
    {:ok, project} = Project.load(:rebar3, root)
    initial = Proof.inventory!(project)
    assert Map.has_key?(initial, :telemetry)
    source = Path.join(root, "_checkouts/telemetry/src/telemetry.erl")
    File.write!(source, File.read!(source) <> "\n% changed reviewed contract\n")
    refute Proof.inventory!(project) == initial
    File.rm!(source)
    assert_raise File.Error, fn -> Proof.inventory!(project) end
  end
end
