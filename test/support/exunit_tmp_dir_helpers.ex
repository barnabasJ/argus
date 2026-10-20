defmodule Argus.Test.Fixtures.ExUnitTmpDir.Helpers do
  def root, do: Path.join(System.tmp_dir!(), "argus-manual-helper")
  def identity(path), do: path
  def create(path), do: File.mkdir_p!(Path.join(path, "child"))

  def safe_field(map), do: map.safe
  def safe_tuple(tuple), do: elem(tuple, 0)

  def fixed(_path), do: "fixtures/fixed"
end
