defmodule TempDirExample.NamedSetupAllTest do
  use ExUnit.Case, async: true

  setup_all :create_shared_directory

  defp create_shared_directory(_context) do
    # Deliberate violation in a named setup_all callback. This registration
    # must be followed just like the inline setup_all callback.
    directory = Path.join(System.tmp_dir!(), "argus-named-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)
    File.mkdir_p!(directory)
    {:ok, shared_directory: directory}
  end

  test "uses the shared fixture", %{shared_directory: directory} do
    assert File.dir?(directory)
  end
end
