defmodule Argus.Test.Fixtures.ExUnitTmpDir.Product do
  # Product behavior remains product behavior when exercised by a test.
  def run, do: File.mkdir_p!(Path.join(System.tmp_dir!(), "argus-product"))
end

defmodule Argus.Test.Fixtures.ExUnitTmpDir do
  use ExUnit.Case, register: false

  alias Argus.Test.Fixtures.ExUnitTmpDir.Helpers

  @moduletag tmp_dir: true

  setup_all do
    # Deliberate violation. Per-test context.tmp_dir does not exist in setup_all.
    File.mkdir_p!(Path.join(System.tmp_dir!(), "argus-shared-inline"))
    :ok
  end

  setup_all :named_shared_setup

  defp named_shared_setup(_context) do
    File.mkdir_p!(Path.join(System.tmp_dir(), "argus-shared-named"))
    :ok
  end

  setup do
    File.mkdir_p!(Path.join(System.tmp_dir!(), "argus-setup"))
    :ok
  end

  test "manual root" do
    File.mkdir_p!(Path.join(System.tmp_dir!(), "argus-manual"))
  end

  test "manual root through helpers" do
    Helpers.root() |> Helpers.identity() |> Helpers.create()
  end

  test "child beneath the ExUnit directory", %{tmp_dir: tmp_dir} do
    Helpers.create(tmp_dir)
  end

  test "unrelated temporary-directory read", %{tmp_dir: tmp_dir} do
    _os_root = System.tmp_dir!()
    File.mkdir_p!(Path.join(tmp_dir, "safe"))
  end

  test "two calls to the same returning helper do not share values", %{tmp_dir: tmp_dir} do
    _discarded = Helpers.identity(System.tmp_dir!())
    safe = Helpers.identity(tmp_dir)
    File.mkdir_p!(safe)
  end

  test "a helper can discard its manual-root argument" do
    safe = Helpers.fixed(System.tmp_dir!())
    File.mkdir_p!(safe)
  end

  test "an absolute path ignores expand's temporary base" do
    safe = Path.expand("/fixtures/fixed", System.tmp_dir!())
    File.mkdir_p!(safe)
  end

  test "Erlang absname ignores an absolute first path's temporary base" do
    safe = :filename.absname(~c"/fixtures/fixed", System.tmp_dir!())
    File.mkdir_p!(safe)
  end

  test "Erlang join ignores its temporary base before an absolute path" do
    safe = :filename.join(System.tmp_dir!(), ~c"/fixtures/fixed")
    File.mkdir_p!(safe)
  end

  test "Erlang list join can discard the temporary prefix" do
    safe = :filename.join([System.tmp_dir!(), ~c"/fixtures/fixed"])
    File.mkdir_p!(safe)
  end

  test "Erlang relative paths retain a manual temporary root" do
    File.mkdir_p!(:filename.absname(~c"argus-relative", System.tmp_dir!()))
    File.mkdir_p!(:filename.join(System.tmp_dir!(), ~c"argus-relative"))
  end

  test "an unrelated manual root in a map does not taint a selected safe field", %{
    tmp_dir: tmp_dir
  } do
    safe = Helpers.safe_field(%{safe: tmp_dir, ignored: System.tmp_dir!()})
    File.mkdir_p!(safe)
  end

  test "an unrelated manual root in a tuple does not taint a selected safe field", %{
    tmp_dir: tmp_dir
  } do
    safe = Helpers.safe_tuple({tmp_dir, System.tmp_dir!()})
    File.mkdir_p!(safe)
  end

  test "application code exercised by a test is not test-owned setup" do
    Argus.Test.Fixtures.ExUnitTmpDir.Product.run()
  end

  test "relative expand retains its temporary base" do
    File.mkdir_p!(Path.expand("argus-expand", System.tmp_dir!()))
  end

  describe "nested setup" do
    setup :nested_setup

    test "body itself stays safe", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "child"))
    end
  end

  defp nested_setup(_context) do
    File.mkdir_p!(Path.join(System.tmp_dir!(), "argus-described"))
    :ok
  end

  test "constant directory is not evidence of a temporary root" do
    File.mkdir_p!("fixtures/output")
  end
end
