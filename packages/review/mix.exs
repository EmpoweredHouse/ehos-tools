defmodule Review.MixProject do
  use Mix.Project

  def project do
    [
      app: :review,
      version: "0.1.0",
      elixir: "~> 1.18",
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  defp deps do
    [
      # The gate is EhosApp.Review, every application's (T-17). By path: this package is never
      # released, and reviews the ehos_app beside it.
      {:ehos_app, path: "../ehos_app"},
      {:credo, "~> 1.7", only: :test, runtime: false},
      {:dialyxir, "~> 1.4", only: :test, runtime: false}
    ]
  end

  # The PLTs live in `_build/`, which CI caches. The review task is a Mix task, so Mix is in
  # the PLT.
  defp dialyzer,
    do: [plt_core_path: "_build/plts", plt_local_path: "_build/plts", plt_add_apps: [:mix]]

  # Credo and Dialyzer are test-only dependencies, so a tool that runs this package in `dev`
  # (the review gate's hook, the `review section` workflow) needs no `deps.get` for them.
  def cli, do: [preferred_envs: [check: :test, credo: :test, dialyzer: :test]]

  def application, do: []

  defp aliases do
    [
      check: [
        &hex_audit/1,
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "credo --config-file ../../.credo.exs",
        "test --warnings-as-errors",
        "dialyzer"
      ]
    ]
  end

  # `mix hex.audit`, first in `check`, as a process of its own: run as a task of the alias it is
  # not found after `compile`, which prunes Hex's archive from the code paths, and a finding does
  # not stop the steps after it (ehos-tools#507). Hex before 2.5 audits retirements alone, and
  # 2.5.0 cannot acknowledge an advisory. `MIX_ENV` is passed on, since `preferred_envs` sets the
  # alias's environment without exporting it.
  defp hex_audit(_args) do
    Application.load(:hex)
    hex = to_string(Application.spec(:hex, :vsn) || "0.0.0")

    if Version.match?(hex, "< 2.5.1") do
      Mix.raise(
        "mix hex.audit needs Hex 2.5.1 or later for advisories, and this is #{hex}: run mix local.hex --force"
      )
    end

    case Mix.shell().cmd("mix hex.audit", env: [{"MIX_ENV", to_string(Mix.env())}]) do
      0 -> :ok
      status -> Mix.raise("mix hex.audit exited with #{status}", exit_status: status)
    end
  end
end
