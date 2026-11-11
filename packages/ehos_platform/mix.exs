defmodule EhosPlatform.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  @version "0.17.0-dev"

  def project do
    [
      app: :ehos_platform,
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

  # The installation code eh-os's tooling and `ehosctl`'s platform plane share (eh-os D-92). It
  # depends on nothing of EHOS's: it runs `tofu`, `ssh`, `helm` and `kubectl` on what a source
  # gives it.
  defp deps do
    [
      {:jason, "~> 1.4"},
      # What the operator's own address is, for the server's SSH rule (`EhosPlatform.Server`).
      {:req, "~> 0.5"},
      # The kubeconfig k3s writes on the server.
      {:yaml_elixir, "~> 2.11"},
      # eh-os D-158: whether a host is a registered domain itself, by the Public Suffix List.
      {:public_sufx, "~> 0.7"},
      {:hammox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: :test, runtime: false},
      {:dialyxir, "~> 1.4", only: :test, runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false}
    ]
  end

  # The PLTs live in `_build/`, which CI caches. Mix and ExUnit are in them, since the
  # repository's conventions case is compiled in `test`, where this runs, and calls both.
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
  # run in `test`, where they are. A project that depends on this package never gets them.
  def cli, do: [preferred_envs: [check: :test, credo: :test, dialyzer: :test]]

  # An application with no processes: it is one so that a release carries its `priv/`, the
  # manifests the installer applies.
  def application, do: [extra_applications: [:crypto]]

  defp aliases do
    [
      "ehos_platform.release_file": &release_file/1,
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
        "https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_platform/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md"],
      # The repository's conventions case is compiled in `test`, where the gate builds this, and
      # is no part of what the package is (ehos-tools#690).
      filter_modules: fn _module, %{source_path: path} ->
        not String.contains?(to_string(path), "/test/support/")
      end,
      # EHOS's release command, which `Install.invite/1` runs in the cluster: not this package's,
      # and in `test`, where the gate builds the docs, a hidden stand-in from `test/support`.
      skip_code_autolink_to: ["Ehos.Release.invite/1"],
      # The changelog names functions later releases removed.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_modules: [
        Installing: [EhosPlatform.Install, EhosPlatform.Source],
        Server: [EhosPlatform.Server, EhosPlatform.Server.Provider],
        "Ways out": [
          EhosPlatform.CommandRunner,
          EhosPlatform.CommandRunnerImpl,
          EhosPlatform.Env,
          EhosPlatform.EnvImpl,
          EhosPlatform.Clock,
          EhosPlatform.ClockImpl,
          EhosPlatform.PublicAddress,
          EhosPlatform.PublicAddressImpl
        ],
        Helpers: [EhosPlatform.Shell, EhosPlatform.TmpDir, EhosPlatform.Tools]
      ]
    ]
  end

  # `mix ehos_platform.release_file --commit <sha> [--output <path>]`: the release's
  # `release.json`, from `EhosPlatform.release/1` (eh-os D-91), for the release workflow. An alias,
  # not a task, so that a project depending on this package does not get it.
  defp release_file(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [commit: :string, output: :string])
    commit = opts[:commit]

    unless rest == [] and is_binary(commit) and commit =~ ~r/\A[0-9a-f]{40}\z/ do
      Mix.raise("Usage: mix ehos_platform.release_file --commit <full sha> [--output <path>]")
    end

    Mix.Task.run("compile")
    :ok = Application.ensure_loaded(:ehos_platform)
    output = Keyword.get(opts, :output, "release.json")
    # Called through apply/3: the module is the package's, compiled after this file.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    File.write!(output, [JSON.encode!(apply(EhosPlatform, :release, [commit])), ?\n])
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
