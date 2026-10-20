# ExUnit temporary directories

`exunit_tmp_dir` checks test code that creates manual temporary directories
where ExUnit can manage per-test fixture directories.

## Analyze `.exs` tests

An ordinary `mix argus` scan reads persisted application BEAMs. Mix normally
compiles `.exs` tests in memory, so that scan does not include most tests.

Use the test capture task instead:

```sh
MIX_ENV=test mix argus.test exunit_tmp_dir
MIX_ENV=test mix argus.test exunit_tmp_dir -- test/example_test.exs
```

Argus options precede `--`. Mix test options and paths follow it:

```sh
MIX_ENV=test mix argus.test exunit_tmp_dir --fail-on warning -- --max-cases 1
```

The task uses `mix test --dry-run` to compile the selected test files and
capture their BEAMs. It passes those BEAMs through the existing Project, Scan,
Driver, Graph, Datalog, and reporting stages. It does not implement a second
analysis runner. The test scan uses its own native manifest. Each invocation
captures the current file selection, so deleted test modules and modules outside
that selection do not remain in the analysis. Analysis covers each compiled
module in full. `--only`, tag, test-name, and line filters do not remove
functions from its BEAM. Filtered and skipped test functions in a compiled
module remain in the analysis.

The task does not execute test bodies, `setup`, or `setup_all`. It does execute
application startup, `test_helper.exs`, and other top-level compilation code. It
is not a sandbox for untrusted tests. The task hides dry-run test listings and
the test summary by default. Capture and analysis phase messages go to stderr.
Compiler warnings, errors, and initialization output remain visible; ordinary
Mix compilation output can still precede a JSON report. An explicit native
`--formatter` after `--` keeps that formatter's dry-run output. Compilation
errors stop the command before analysis.

## Read a finding

The warning title is **ExUnit creates a manual temporary directory**. The
primary location marks the directory-creation call with **manual temporary
directory created here**. A related location marks the `System.tmp_dir/0` or
`System.tmp_dir!/0` call with **OS temporary directory selected here**.

The note names the test or callback and the function that creates the directory.
These can be different functions when the test calls a helper. The help depends
on the callback lifecycle: a test or `setup` can use the ExUnit directory, while
`setup_all` needs the separate treatment described below.

The runnable example reports four warnings. This abbreviated native CLI excerpt
shows a test calling a helper that returns the manual root:

```text
warning[argus.exunit_tmp_dir]: ExUnit creates a manual temporary directory
   ╭─[test/per_test_test.exs:27:5]
...
27 │     File.mkdir_p!(directory)
...
   •                ╰── manual temporary directory created here
...
   ├─[test/support/paths.ex:8:5]
...
   •                                              ╰── OS temporary directory selected here
```

The primary location points to directory creation in the test. The related
location points to the root's source in the helper. These findings come from
compiled code; no test or setup callback body ran.

## Use the ExUnit root

Replace a manual root:

```elixir
test "writes a fixture" do
  directory = Path.join(System.tmp_dir!(), "my-fixture")
  File.mkdir_p!(directory)
  on_exit(fn -> File.rm_rf!(directory) end)
end
```

with a directory owned by ExUnit:

```elixir
@tag :tmp_dir
test "writes a fixture", %{tmp_dir: tmp_dir} do
  directory = Path.join(tmp_dir, "fixtures")
  File.mkdir_p!(directory)
end
```

A unique name and an `on_exit` cleanup do not change the first example's
ownership. The second example gives ExUnit the fixture root and keeps child
directories inside it. Per-test `setup` can also read `context.tmp_dir`.

## `setup_all` has a different lifecycle

The analysis follows both inline and named `setup_all` registrations. A manual
temporary root in either callback is still relevant to the rule.

Do not fix a `setup_all` finding by reading `context.tmp_dir` there. ExUnit
creates that directory per test, after `setup_all`. Move the fixture to per-test
`setup` when possible. When a fixture must be shared, design and document its
shared lifecycle separately; this analysis does not infer that a shared root has
an adequate cleanup policy.

## Scope and limitations

The analysis uses compiled ExUnit callback registrations and native call facts.
It follows temporary-path provenance from `System.tmp_dir/0` and
`System.tmp_dir!/0`, through supported path constructors and project helpers, to
directory creation. The directory-creating function must belong to an ExUnit
case or native test-support module. A production filesystem function does not
become a violation merely because a test calls it. A production helper that
returns an OS temporary path can still lead to a finding when test code creates
that directory. A child built from `context.tmp_dir` is not a manual root.

This is a static check, not proof that all filesystem operations use an isolated
directory. Arbitrary dynamic calls, custom path builders, hard-coded temporary
paths, and external code without selected BEAMs can limit coverage. A missing
finding does not prove that a path belongs to ExUnit. Container projections (map
fields, tuple elements, or list elements) are conservatively unresolved:
whole-value provenance cannot tell which field contains a root. The analysis
also leaves `:filename.join/1` unresolved because an absolute list component can
discard earlier components. Scalar helper arguments and returns remain tracked;
`Path.join/1,2`, `Path.expand/1,2`, and relative `:filename.join/2` and
`:filename.absname/1,2` preserve temporary-path provenance.

The [runnable example](../../examples/exunit_tmp_dir/README.md) includes
intentional findings, helper calls, both `setup_all` forms, and nearby correct
cases.
