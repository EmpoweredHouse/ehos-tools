defmodule EhosRelease.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  @version "0.1.0-dev"

  def project do
    [
      app: :ehos_release,
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

  # What the release workflow runs (T-34). Req calls GitHub's API, and yaml_elixir reads a
  # caller's workflows as data; JSON is Elixir's own.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.12"},
      {:hammox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: :test, runtime: false},
      {:dialyxir, "~> 1.4", only: :test, runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false}
    ]
  end

  # The PLTs live in `_build/`, which CI caches. Mix and ExUnit are in them, since the tasks call
  # Mix, and the repository's conventions case, compiled in `test`, calls both.
  defp dialyzer,
    do: [
      plt_core_path: "_build/plts",
      plt_local_path: "_build/plts",
      plt_add_apps: [:mix, :ex_unit]
    ]

  # The repository's conventions case every package's tests share (ehos-tools#690), by an
  # absolute path, since Mix reads a relative one as inside the project.
  defp elixirc_paths(:test),
    do: ["lib", "test/support", Path.expand("../../test/support", __DIR__)]

  defp elixirc_paths(_env), do: ["lib"]

  # Credo and Dialyzer are test-only dependencies, so `mix check`, `mix credo` and `mix dialyzer`
  # run in `test`, where they are.
  def cli, do: [preferred_envs: [check: :test, credo: :test, dialyzer: :test]]

  # No processes of its own: each task runs once and ends.
  def application, do: [extra_applications: [:logger]]

  defp aliases do
    [
      "ehos_release.release_file": &release_file/1,
      # The repository's `.credo.exs`, whichever way Credo is run (`.credo.exs` says why).
      credo: "credo --config-file ../../.credo.exs",
      check: [
        &hex_audit/1,
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "credo",
        "test --warnings-as-errors",
        "dialyzer",
        "docs --warnings-as-errors"
      ]
    ]
  end

  # The documentation, built by `mix docs` into `doc/`. The gate builds it with warnings as
  # errors, so a reference to a module or function that does not exist fails it.
  defp docs do
    [
      main: "readme",
      source_url_pattern:
        "https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_release/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md"],
      # The repository's conventions case is compiled in `test`, where the gate builds this, and
      # is no part of what the package is (ehos-tools#690).
      filter_modules: fn _module, %{source_path: path} ->
        not String.contains?(to_string(path), "/test/support/")
      end,
      groups_for_modules: [
        "What a repository says": [EhosRelease.Config, EhosRelease.Producers],
        Pins: [
          EhosRelease.Pin,
          EhosRelease.Pins,
          EhosRelease.PinCheck,
          EhosRelease.MixLock,
          EhosRelease.Source
        ],
        "Ways out": [
          EhosRelease.GitHub,
          EhosRelease.GitHubImpl,
          EhosRelease.Git,
          EhosRelease.GitImpl
        ]
      ]
    ]
  end

  # `mix ehos_release.release_file --commit <sha> [--output <path>]`: the release's
  # `release.json`, from `EhosRelease.release/1` (eh-os D-91), for `release-package.yml`. An alias,
  # not a task, as the other packages' are.
  defp release_file(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [commit: :string, output: :string])
    commit = opts[:commit]

    unless rest == [] and is_binary(commit) and commit =~ ~r/\A[0-9a-f]{40}\z/ do
      Mix.raise("Usage: mix ehos_release.release_file --commit <full sha> [--output <path>]")
    end

    Mix.Task.run("compile")
    :ok = Application.ensure_loaded(:ehos_release)
    output = Keyword.get(opts, :output, "release.json")
    # Called through apply/3: the module is the package's, compiled after this file.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    File.write!(output, [JSON.encode!(apply(EhosRelease, :release, [commit])), ?\n])
    Mix.shell().info("wrote #{output}")
  end

  # `mix hex.audit`, first in `check`, as a process of its own: run as a task of the alias it is
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
