defmodule TempDirExample.Export do
  @moduledoc "A normal application filesystem operation, outside an ExUnit callback."

  @spec write(directory :: Path.t(), content :: String.t()) :: :ok
  def write(directory, content) do
    # This application API is not a test fixture. The analysis must not treat
    # every File.mkdir_p! call in a selected application as a violation.
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "export.txt"), content)
  end
end
