defmodule Review.MixProject do
  use Mix.Project

  def project do
    [
      app: :review,
      version: "0.1.0",
      elixir: "~> 1.18",
      aliases: aliases(),
      # The gate is EhosApp.Review, every application's (T-17). By path: this package is never
      # released, and reviews the ehos_app beside it.
      deps: [{:ehos_app, path: "../ehos_app"}]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

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
