defmodule TempDirExample.Paths do
  @moduledoc "An intentionally incorrect test helper for the analysis example."

  @spec manual_root() :: Path.t()
  def manual_root do
    # Deliberate violation when called from a test: hiding the temporary root
    # behind a helper does not give ExUnit ownership of its lifecycle.
    Path.join(System.tmp_dir!(), "argus-example-#{System.unique_integer([:positive])}")
  end
end
