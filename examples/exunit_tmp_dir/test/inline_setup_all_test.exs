defmodule TempDirExample.InlineSetupAllTest do
  use ExUnit.Case, async: true

  setup_all do
    # Deliberate violation: this is a shared manual root. ExUnit's per-test
    # tmp_dir is not available in setup_all, so adding @moduletag :tmp_dir
    # would not fix this callback. Move this fixture to per-test setup.
    directory = Path.join(System.tmp_dir!(), "argus-inline-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)
    File.mkdir_p!(directory)
    {:ok, shared_directory: directory}
  end

  test "uses the shared fixture", %{shared_directory: directory} do
    assert File.dir?(directory)
  end
end
