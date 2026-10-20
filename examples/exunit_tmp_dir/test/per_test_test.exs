defmodule TempDirExample.PerTestTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "uses the ExUnit directory and creates a child", %{tmp_dir: tmp_dir} do
    # Correct: ExUnit owns the root; children remain within that root.
    directory = Path.join(tmp_dir, "fixtures")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "input.txt"), "example")
    assert File.read!(Path.join(directory, "input.txt")) == "example"
  end

  test "creates a manual temporary root" do
    # Deliberate violation: a unique suffix avoids collisions, but the test
    # still reimplements ExUnit's temporary-directory lifecycle.
    directory = Path.join(System.tmp_dir!(), "argus-direct-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)
    File.mkdir_p!(directory)
    assert File.dir?(directory)
  end

  test "gets a manual temporary root from a helper" do
    # Deliberate violation across a function boundary.
    directory = TempDirExample.Paths.manual_root()
    on_exit(fn -> File.rm_rf!(directory) end)
    File.mkdir_p!(directory)
    assert File.dir?(directory)
  end
end
