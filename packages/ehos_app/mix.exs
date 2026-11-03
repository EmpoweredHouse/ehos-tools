defmodule EhosApp.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  # A project takes a change to what the installer writes by moving its dependency to the
  # commit a release's tag names and running the installer again (ehos-tools T-02).
  # `mix igniter.upgrade` would compare it too, but ehos_app has no upgrade steps.
  @version "0.29.0-dev"

  def project do
    [
      app: :ehos_app,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      package: [licenses: ["Apache-2.0"]],
      source_url: "https://github.com/EmpoweredHouse/ehos-tools",
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Credo and Dialyzer are test-only dependencies, so `mix check`, `mix check.static`,
  # `mix credo` and `mix dialyzer` run in `test`, where they are. A project that depends on this
  # package never gets them.
  def cli,
    do: [preferred_envs: [check: :test, "check.static": :test, credo: :test, dialyzer: :test]]

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    [
      "ehos_app.release_file": &release_file/1,
      # The repository's `.credo.exs`, whichever way Credo is run (`.credo.exs` says why).
      credo: "credo --config-file ../../.credo.exs",
      # The gate is `check`. CI runs `check.static` in one job and the tests, which run the
      # installer hundreds of times, split across several (`mix test --partitions`).
      check: gate(["test --warnings-as-errors"]),
      "check.static": gate([])
    ]
  end

  # The tests before Dialyzer and the docs, so a failing test fails the gate before they run.
  defp gate(tests) do
    [&hex_audit/1, "format --check-formatted", "compile --force --warnings-as-errors", "credo"] ++
      tests ++ ["dialyzer", "docs --warnings-as-errors"]
  end

  # The documentation, built by `mix docs` into `doc/`. The gate builds it with warnings as
  # errors, so a reference to a module or function that does not exist fails it.
  defp docs do
    [
      main: "readme",
      source_url_pattern:
        "https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_app/%{path}#L%{line}",
      # Not the changelog: its released sections link the repository's decision records by paths
      # relative to it, which a released section keeps and the generated reference would break.
      # The README links it on GitHub.
      extras: ["README.md"],
      groups_for_modules: [
        Release: [EhosApp, EhosApp.Toolchain],
        "Review gate": [EhosApp.Review, EhosApp.Env, EhosApp.EnvImpl]
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
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
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
      {:jsv, "~> 0.26.2", only: :test},
      {:hammox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: :test, runtime: false},
      {:dialyxir, "~> 1.4", only: :test, runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false}
    ]
  end

  # The PLTs live in `_build/`, which CI caches. The installer and the review gate are Mix tasks
  # on Igniter, so Mix and Igniter are in the PLT, and ExUnit, which the installer's tests' case
  # in `test/support/` is built on.
  defp dialyzer,
    do: [
      plt_core_path: "_build/plts",
      plt_local_path: "_build/plts",
      plt_add_apps: [:mix, :igniter, :ex_unit]
    ]

  # `mix hex.audit`, first in `gate/1`, as a process of its own: run as a task of the alias it is
  # not found after `compile`, which prunes Hex's archive from the code paths, and a finding does
  # not stop the steps after it (ehos-tools#507). Hex before 2.5 audits retirements alone, 2.5.0
  # cannot acknowledge an advisory, and before 2.6.0 an audit whose registry fetch failed passed
  # without checking the package. `MIX_ENV` is passed on, since `preferred_envs` sets the
  # alias's environment without exporting it.
  defp hex_audit(_args) do
    Application.load(:hex)
    hex = to_string(Application.spec(:hex, :vsn) || "0.0.0")

    if Version.match?(hex, "< 2.6.0") do
      Mix.raise(
        "mix hex.audit needs Hex 2.6.0 or later, and this is #{hex}: run mix local.hex --force"
      )
    end

    case Mix.shell().cmd("mix hex.audit", env: [{"MIX_ENV", to_string(Mix.env())}]) do
      0 -> :ok
      status -> Mix.raise("mix hex.audit exited with #{status}", exit_status: status)
    end
  end
end
