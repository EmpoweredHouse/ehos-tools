defmodule Review.MixProject do
  use Mix.Project

  def project do
    [
      app: :review,
      version: "0.1.0",
      elixir: "~> 1.18",
      aliases: aliases(),
      deps: []
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
