# Argus

[![CI](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/argus_beam.svg)](https://hex.pm/packages/argus_beam)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/argus_beam)

Argus finds OTP and concurrency bugs in Elixir, Erlang and Gleam programs:

- supervisor children that depend on each other but restart independently;
- GenServers that deadlock calling each other;
- races on a registered name or an ETS key.

It analyzes compiled `.beam` files and reports findings at the source lines
involved.

![Argus reports a restart dependency between two children of a one_for_one supervisor](https://raw.githubusercontent.com/QuinnWilton/argus/main/images/coupling.png)

## Install and run

Argus runs its analyses on [FlowLog](https://github.com/flowlog-rs/flowlog)
engines: incremental Datalog that keeps its results up to date as your code changes,
so a recompile re-derives only what an edit reached. The Mix integration requires
Elixir 1.19 or later; prebuilt escripts require Erlang/OTP 28.

On macOS and Linux (arm64 or x86_64), a release ships its engines prebuilt: the
first run downloads them once (about 70 MB, checked against the SHA-256 the package
names) and needs no Rust, for argus's own analyses and for rules files of your own,
which run in the generic engine the download carries. Elsewhere, argus builds its
toolchain with [Rust](https://rustup.rs) 1.88 or later, once: a few minutes. Every
program then runs at once in the generic engine, and `mix argus.flowlog build`
compiles engines for argus's own, which solve a large project up to twice as fast.
`ARGUS_FLOWLOG_PREBUILT=0` turns the download off, so argus builds everything itself.
On Linux the prebuilt engines are linked static, so they run on any distribution:
glibc or musl (Alpine), old or new, and NixOS. Where argus builds its own, it needs
Rust and a C compiler (on NixOS, `nix-shell -p cargo rustc gcc`). A download that
fails is tried again an hour later (or at once by `mix argus.flowlog build`), not
at every compile.

`ARGUS_OFFLINE=1` (or `--offline` on `mix argus`, `mix argus.flowlog`, the escript
and `rebar3 argus`) makes no network call: argus uses prebuilt engines only once
they are downloaded, Cargo builds from the crates `~/.cargo` already holds, and
`priors: :live` answers from the cache alone.

Build or fetch the engines ahead of time, in CI for instance, with
`mix argus.flowlog build`, and see what is installed with `mix argus.flowlog status`.
`ARGUS_FLOWLOG_ENGINE=generic` runs every program in the generic engine, and
`compiled` builds an engine for every program, rules files of your own included.
They live in `~/.cache/argus/flowlog` (`ARGUS_FLOWLOG_DIR` names another directory,
`ARGUS_CARGO` another `cargo`); `mix argus.flowlog clean` removes those of earlier
releases.

### Mix

Add Argus to your dependencies:

```elixir
def deps do
  [
    {:argus_beam, "~> 0.24", only: [:dev, :test], runtime: false}
  ]
end
```

`only:` and `runtime: false` keep Argus out of production builds and releases.

Then fetch dependencies and run an analysis. `mix argus` compiles the project first.

```sh
mix deps.get
mix argus                 # configured analyses, or the default set
mix argus coupling ets    # selected analyses
mix argus --all           # all bug-finding analyses
mix argus --list          # available analyses and sets
mix argus --format json   # findings as JSON
mix argus --fail-above 0  # fail CI on any finding
mix argus --fail-on error # fail CI on an error-severity finding
```

To report findings on every compile, append the `:argus` compiler. Editors can
show the findings as compiler diagnostics.

```elixir
def project do
  [
    compilers: Mix.compilers() ++ if(Mix.env() in [:dev, :test], do: [:argus], else: []),
    argus: [analyses: [:default, :ets], severity: [mailbox: :error]]
  ]
end
```

List `:argus` only in the environments that have the dependency: in any other,
such as a `MIX_ENV=prod` release build, Mix stops with "The task compile.argus
could not be found".

By default, error findings fail the compiler run. `mix argus` uses `--fail-above`
to decide whether findings fail the run.

### rebar3

Add this to `rebar.config`, then run `rebar3 argus`. The plugin compiles the
project and downloads the specified Argus escript.

```erlang
{plugins, [rebar3_argus]}.
{argus_plugin, [{version, "0.24.0"}]}.
{argus, [{analyses, [default, ets]}]}.           % optional
{provider_hooks, [{post, [{compile, argus}]}]}.  % optional: run after compilation
```

### Gleam, erlang.mk, or a directory of BEAM files

Install the escript with Mix:

```sh
mix escript.install hex argus_beam
```

Or download a prebuilt escript and its SHA-256 checksum from
[GitHub releases](https://github.com/QuinnWilton/argus/releases). Put `argus` on
your `PATH`.

Build your project, then run:

```sh
argus                                 # current project
argus path/to/project --all
argus --project beams --ebin path/to/ebin
```

The escript reads existing BEAM files and warns about sources newer than their
compiled files. Configuration goes in `argus.config` as Erlang terms. Gleam
findings point to the generated Erlang source.

## Choose analyses

The analyses marked ✓ run by default.

| Analysis | Finds | Default |
|---|---|:---:|
| `startup` | blocking work, deadlocks and races during initialization | ✓ |
| `shutdown` | skipped cleanup, teardown that disrupts a peer, and programs a killed task leaves running | ✓ |
| `coupling` | processes that depend on each other but restart independently | ✓ |
| `structure` | invalid child specs, conflicting registrations and supervision mistakes | ✓ |
| `mailbox` | unhandled messages, missing replies and repeated resource acquisitions | ✓ |
| `failure` | swallowed errors, unchecked results and dropped resources | ✓ |
| `races` | check-then-act races on registered names, ETS keys or Mnesia records | ✓ |
| `blocking` | call cycles, nested waits, bottlenecks and unsafe distributed calls | |
| `state_machine` | unreachable `gen_statem` states and terminal states that never stop | |
| `ets` | table ownership, lifecycle and access-pattern problems | |
| `effects` | effects inside a transaction that a rollback cannot undo | |
| `unsafe_input` | atom exhaustion, unsafe deserialization and code execution | |
| `exposure` | inspect-visible secrets and TLS connections without peer verification | |

Use analysis names or these sets in `analyses:`:

- `:default`: the analyses marked ✓;
- `:all`: every analysis in the table;
- `:security`: `unsafe_input` and `exposure`;
- `:effects`: `effects`;
- `:otp`: `:all` except `:security`, `:effects` and the ExUnit lifecycle rule `:exunit_tmp_dir`.

The separate `coverage` analysis reports missing analysis information. Request it
explicitly; `--all` excludes it.

`severity:` overrides the level for an analysis or set. To keep a finding you have
looked at out of the report without hiding the rest of its module, name its
analysis and where it is:

```elixir
argus: [ignore: [findings: [{:shutdown, MyApp.Writer}, {:races, {MyApp.Reading, :retry, 2}}]]]
```

See the
[configuration reference](https://hexdocs.pm/argus_beam/Argus.Config.html) for
severity, ignore rules and compiler settings.

## Interpret findings

Argus analyzes your project's code by default. Add `--include-deps` to analyze
dependencies too. Dynamic calls and runtime configuration can leave gaps or
produce findings that do not apply to a particular deployment.

Use the [bug-class catalog](docs/bug-classes.md) to understand each finding's
evidence and limits. Start with the [contributor guide](CONTRIBUTING.md) to capture
a finding, inspect its rules and facts, or run a small extension. The
[analysis model](docs/design/analysis-model.md) and
[rule guide](docs/design/rule-style.md) explain the implementation contracts.

## License

MIT

## External analysis modules

Select a module that implements `Argus.Analysis` beside builtin names and sets:

```elixir
argus: [analyses: [:coupling, {MyApp.Analysis, allowed: [MyApp.API]}]]
```

The standard `mix argus` task and `Argus.Driver` run the selection through the
same incremental Graph, Findings and report pipeline. Each module names its
extractors and main Datalog program through the existing callbacks. Return an
absolute `rules_file/0` path, or a path under the analysis application's
`priv/dl`. Programs include their own libraries and input declarations.

The optional `input_facts/1` callback receives the selected options and returns
`%{facts: %{relation: [["raw", "fields"]]}}`. Rows belong only to that selection.
They cannot overwrite extracted or shared-stage relations. Optional `schemas:`
descriptors (`%{name: atom, fields: [{name, kind, doc}]}`) validate declarations
that the compiler removes because they are unused. Raw fields are strings;
number columns hold signed 32-bit integers. Reporting names must be unique.
Callback and program errors degrade their selection without removing other
analyses' findings.

External extractors operate on prepared whole-module data. Declare
`requirements/0` as `[:beam]`, `[:typed]`, or both when those inputs are needed.
The `:beam` value contains immutable bytes supplied by native input discovery.
Use `include_deps: false` for project applications, `true` for every dependency,
or a list such as `include_deps: [:ash, :phoenix]` for specific dependency
applications. Lists do not expand transitively. Unknown application names fail
with a configuration error. Dependencies outside the selection remain available
for native spec resolution.
Every selected analysis shares the same native project program. The optional
`module_data.project?` boolean identifies modules from project application ebins.
Dependency modules have `false`; direct Pipeline and in-memory inputs default to
`true` when no project ebin list is supplied. An explicitly empty list identifies
no project modules. Extractors must not resolve or reopen other BEAM files.

Roux memoizes analyzer code within one VM, for external and builtin analyses.
A new CLI invocation observes changed analyzer code. A long-running caller that
intentionally reloads analyzer modules must call `Roux.Code.forget/0` before the
next Driver run. This resets code identities; the Graph manifest and result
store remain intact. Policy-input and included-program edits need no reset.

### Analyze ExUnit tests

Use `mix argus.test exunit_tmp_dir` to compile tests with native
`mix test --dry-run`, then analyze their captured BEAMs through the same Driver,
graph, extractors and reports as `mix argus`. This requires Elixir 1.19 or
later.

```sh
mix argus.test exunit_tmp_dir
mix argus.test exunit_tmp_dir --fail-on warning -- test/example_test.exs
```

The `exunit_tmp_dir` analysis follows OS temporary-directory paths through
helpers to directory creation in ExUnit tests and test-support code. It
recommends ExUnit's per-test `tmp_dir` for tests and `setup`. Its `setup_all`
findings explain that the per-test directory does not exist in that callback.
Production filesystem functions do not become test-fixture violations merely
because a test calls them.

Select the analysis in `mix.exs` to make it the default for `mix argus.test`:

```elixir
def project do
  [
    # ...
    argus: [analyses: [:exunit_tmp_dir]]
  ]
end
```

See the [analysis guide](docs/analyses/exunit_tmp_dir.md) and
[runnable example](examples/exunit_tmp_dir/README.md) for intentional findings,
helper calls, correct child directories, and named and inline `setup_all` cases.

Put Argus options before `--` and native Mix test options or paths after it.
Without paths, Mix uses the project's normal test paths and patterns. Partial
selection analyzes only the selected test files and compiled helpers. Every
function in a captured module is analyzed; line, tag, and name filters do not
exclude individual test functions from analysis. Filtered and skipped test
functions in those modules remain in the analysis. Captures are fresh each run
and removed afterwards; failed compilation never analyzes partial or previous
captures. The test analysis has a separate native manifest.

Test bodies and `setup`/`setup_all` callbacks do not run. Application startup,
`test_helper.exs`, and top-level compilation code do execute. This command is
not a sandbox. Dry-run listings and the test summary are hidden by default.
Capture and analysis phase messages go to stderr. Compiler diagnostics and
initialization output remain visible, so ordinary Mix compilation output can
still precede JSON findings. Pass a native `--formatter` after `--` to keep
that formatter's dry-run output.
Run this command in a fresh Mix VM; an already-required file under the
configured test paths causes an explicit error instead of an incomplete helper
capture.
