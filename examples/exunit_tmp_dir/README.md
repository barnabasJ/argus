# ExUnit temporary-directory example

This application contains intentional `exunit_tmp_dir` findings. It also
contains nearby correct cases. Each offending call has a comment that explains
the issue.

From this directory, run:

```sh
mix deps.get
MIX_ENV=test mix argus.test exunit_tmp_dir -- --max-cases 1
```

The command compiles the `.exs` tests with Mix's dry-run support. It does not
run the test bodies or their `setup` and `setup_all` callbacks. Application
startup, `test_helper.exs`, and other top-level compilation code still run.

To inspect one file, pass its path after `--`:

```sh
MIX_ENV=test mix argus.test exunit_tmp_dir -- test/named_setup_all_test.exs
```

`argus.test` feeds the captured test BEAMs into Argus's normal scan, Driver,
Datalog analysis, and report pipeline. The captured files are temporary. The
test scan has a separate manifest from the ordinary application scan.

Analysis covers every function in a compiled test module. Mix filters such as
`--only`, tags, test names, or line selections do not remove the other functions
from that module's BEAM. Filtered and skipped test functions remain in the
analysis when their module is compiled.

## Expected output

The complete example reports **4 warnings**: two manual roots in tests and one
in each `setup_all` form. The valid ExUnit child directory and the ordinary
application filesystem function do not produce warnings.

This abbreviated excerpt is from the native CLI output. The omitted lines
contain the source span and explanatory note:

```text
argus.test: compiling project and capturing test BEAMs (test bodies do not run)
argus.test: analyzing captured BEAMs
warning[argus.exunit_tmp_dir]: ExUnit creates a manual temporary directory
   ╭─[test/named_setup_all_test.exs:11:5]
...
     help: Move this work to per-test setup with @tag tmp_dir: true and context.tmp_dir. If shared setup_all state is essential, create a unique directory and register explicit on_exit cleanup.
...
4 findings (4 warnings)
```

No test, `setup`, or `setup_all` body ran to produce these findings. Argus
analyzed the captured compiled functions. The default formatter hides the native
dry-run test listing and test summary. Phase messages go to stderr. Compiler
diagnostics and initialization output remain visible. An explicit native
`--formatter` keeps that formatter's dry-run output.

## What to inspect

| File                             | Case                                                                                         |
| -------------------------------- | -------------------------------------------------------------------------------------------- |
| `test/per_test_test.exs`         | A correct child of `context.tmp_dir`, a manual root, and a manual root returned by a helper. |
| `test/inline_setup_all_test.exs` | A manual root inside an inline `setup_all` callback.                                         |
| `test/named_setup_all_test.exs`  | A manual root inside a named `setup_all` callback.                                           |
| `test/support/paths.ex`          | The helper that returns a manual temporary path.                                             |
| `lib/export.ex`                  | An ordinary application filesystem operation, outside a test callback.                       |

The test-root cases use unique names and cleanup callbacks. They are intentional
findings even though this cleanup makes a normal test run tidy. ExUnit can own
per-test fixture directories without that extra code.

## Fix a per-test fixture

```elixir
@moduletag :tmp_dir

setup %{tmp_dir: tmp_dir} do
  directory = Path.join(tmp_dir, "fixtures")
  File.mkdir_p!(directory)
  {:ok, fixture_directory: directory}
end
```

ExUnit supplies the root for each test. Tests can create child directories and
pass those paths to helpers.

## Do not apply that fix inside `setup_all`

ExUnit's `tmp_dir` tag provides a directory per test. That directory is not
available in `setup_all`, which runs before the individual tests. Adding the tag
does not supply a shared temporary directory to that callback.

Prefer per-test `setup` when a fixture can be isolated. If a fixture must be
shared, define and document its separate lifecycle explicitly. This rule still
reports a manual temporary root reached through `setup_all`; cleanup or a unique
suffix does not make it ExUnit-managed.

See the [analysis guide](../../docs/analyses/exunit_tmp_dir.md) for scope and
limitations.
