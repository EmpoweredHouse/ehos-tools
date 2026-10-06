defmodule EhosApp.MixProject do
  use Mix.Project

  # Moves with every change to what the installer writes: a project takes the change by
  # moving its dependency to the commit this version's tag names and running the installer
  # again (ehos-tools T-02).
  # `mix igniter.upgrade` would compare it too, but ehos_app has no upgrade steps.
  @version "0.5.1"

  def project do
    [
      app: :ehos_app,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "test"
      ]
    ]
  end

  defp deps do
    [
      # Optional, the way every package with an Igniter installer declares it: the
      # installer compiles only where Igniter is present, and an application that
      # depends on this package at runtime does not inherit Igniter. 0.8.4 is the first
      # release without CVE-2026-82584 (terminal escapes in install prompts).
      {:igniter, "~> 0.8.4", optional: true},
      # The installer composes `phx.gen.release`, and its tests build a Phoenix project.
      {:phx_new, "~> 1.8.14", only: :test, runtime: false},
      # The tests check the generated `ehos.yaml` against the JSON Schema EHOS defines it
      # by, as eh-os does: YAML read with yaml_elixir, draft 2020-12 checked with JSV, the
      # one library on Hex that implements it in full.
      {:yaml_elixir, "~> 2.12", only: :test},
      {:jsv, "~> 0.25.0", only: :test}
    ]
  end
end
