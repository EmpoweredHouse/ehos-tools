defmodule EhosApp.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  # A project takes a change to what the installer writes by moving its dependency to the
  # commit a release's tag names and running the installer again (ehos-tools T-02).
  # `mix igniter.upgrade` would compare it too, but ehos_app has no upgrade steps.
  @version "0.14.0-dev"

  def project do
    [
      app: :ehos_app,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: [licenses: ["Apache-2.0"]]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    [
      "ehos_app.release_file": &release_file/1,
      check: [
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "test"
      ]
    ]
  end

  # `mix ehos_app.release_file --commit <sha> [--output <path>]`: the release's `release.json`, from
  # `EhosApp.release/1` (eh-os D-91), for the release workflow. An alias, not a task, so that a
  # project depending on this package does not get it.
  defp release_file(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [commit: :string, output: :string])
    commit = opts[:commit]

    unless rest == [] and is_binary(commit) and commit =~ ~r/\A[0-9a-f]{40}\z/ do
      Mix.raise("Usage: mix ehos_app.release_file --commit <full sha> [--output <path>]")
    end

    Mix.Task.run("compile")
    :ok = Application.ensure_loaded(:ehos_app)
    output = Keyword.get(opts, :output, "release.json")
    # Called through apply/3: the module is the package's, compiled after this file.
    File.write!(output, [JSON.encode!(apply(EhosApp, :release, [commit])), ?\n])
    Mix.shell().info("wrote #{output}")
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
