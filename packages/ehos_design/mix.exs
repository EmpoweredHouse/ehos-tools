defmodule EhosDesign.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ehos_design,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: []
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  # An application with no processes: it is one so that a release carries its `priv/`, and a
  # host serves the fonts with `Plug.Static, from: {:ehos_design, "priv/static"}`.
  def application, do: []

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "test"
      ]
    ]
  end
end
