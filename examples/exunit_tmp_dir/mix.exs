defmodule TempDirExample.MixProject do
  use Mix.Project

  @spec project() :: keyword()
  def project do
    [
      app: :temp_dir_example,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [{:argus_beam, path: "../..", runtime: false}]
    ]
  end

  @spec application() :: keyword()
  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]
end
