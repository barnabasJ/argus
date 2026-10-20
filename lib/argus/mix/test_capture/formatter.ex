defmodule Argus.Mix.TestCapture.Formatter do
  @moduledoc false

  use GenServer

  @impl true
  @spec init(options :: keyword()) :: {:ok, nil}
  def init(_options), do: {:ok, nil}

  @impl true
  @spec handle_cast(event :: term(), state :: nil) :: {:noreply, nil}
  def handle_cast(_event, state), do: {:noreply, state}
end
