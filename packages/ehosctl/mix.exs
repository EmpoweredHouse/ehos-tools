defmodule Ehosctl.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  @version "0.29.0-dev"

  def project do
    [
      app: :ehosctl,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      releases: releases(),
      deps: deps(),
      dialyzer: dialyzer(),
      # EEF-CVE-2026-43966, response splitting in cowlib's `escape_string/2`, has no release that
      # fixes it. cowlib comes only through bypass, a test dependency whose fake provider answers
      # this package's own tests on a local port; the binary carries neither. `mix hex.audit` is
      # told so, and this goes once cowlib has a fixed release.
      hex: [ignore_advisories: ["EEF-CVE-2026-43966"]],
      package: [licenses: ["Apache-2.0"]],
      name: "ehosctl",
      source_url: "https://github.com/EmpoweredHouse/ehos-tools",
      docs: docs()
    ]
  end

  # Credo and Dialyzer are test-only dependencies, so `mix check`, `mix credo` and `mix dialyzer`
  # run in `test`, where they are.
  def cli, do: [preferred_envs: [check: :test, credo: :test, dialyzer: :test]]

  # A fake EHOS and a fake keychain, for the tests of signing in.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [extra_applications: [:logger, :crypto], mod: {Ehosctl.Application, []}]
  end

  defp aliases do
    [
      # The repository's `.credo.exs`, whichever way Credo is run (`.credo.exs` says why).
      credo: "credo --config-file ../../.credo.exs",
      check: [
        &hex_audit/1,
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "credo",
        "test --warnings-as-errors",
        # `ehos_platform` is a path dependency, which `mix.lock` does not name, so a cached PLT
        # passes dialyxir's check while it holds an older `ehos_platform`: CI then reads a module
        # this change added as unknown (#542). `--force-check` compares the PLT with the beams.
        "dialyzer --force-check",
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
        "https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Command line": [Ehosctl.CLI, Ehosctl.Command, Ehosctl.Output],
        Commands: [
          Ehosctl.Init,
          Ehosctl.Installations,
          Ehosctl.Login,
          Ehosctl.Logout,
          Ehosctl.Whoami
        ],
        "Signing in": [
          Ehosctl.SignIn,
          Ehosctl.SignIn.Loopback,
          Ehosctl.Credentials,
          Ehosctl.TokenStore,
          Ehosctl.TokenStore.Keychain,
          Ehosctl.TokenStore.SecretService,
          Ehosctl.TokenStore.File
        ],
        Configuration: [Ehosctl.Config, Ehosctl.PrivateFile, Ehosctl.Template, Ehosctl.Version],
        "Versions and releases": [
          Ehosctl.Versions,
          Ehosctl.Changelog,
          Ehosctl.Acceptance,
          Ehosctl.GitHub,
          Ehosctl.Project,
          Ehosctl.Notice
        ]
      ]
    ]
  end

  # One binary per target, each carrying its own ERTS, so `ehosctl` runs on a machine
  # with no Erlang at all: the runtime the generated project needs is mise's to install,
  # not a precondition of the tool that installs it. `BURRITO_TARGET=macos_arm64` builds
  # one target instead of all four.
  #
  # The binary is named `ehosctl_<target>`, and the names are chosen for mise's `github:`
  # backend, which picks a release asset by the OS and architecture words in its name:
  # `x64` and `arm64` score in full, while a bare `x86` reads as 32-bit and a bare `arm`
  # as armv7.
  defp releases do
    [
      ehosctl: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            macos_x64: [os: :darwin, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            linux_x64: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      # 1.6.0 builds with Zig 0.16.0 and refuses any other version.
      {:burrito, "~> 1.6"},
      # T-06: the command line is declared with Optimus, and what a person reads is
      # written with Owl.
      {:optimus, "~> 0.6"},
      {:owl, "~> 0.13"},
      # eh-os D-92: the code that makes a server and installs EHOS, shared with eh-os, from this
      # repository; the platform plane runs it (T-13).
      {:ehos_platform, path: "../ehos_platform"},
      # T-09: signing in is oidcc's, the library EHOS's provider is tested against. 3.9.0 is
      # the first that fixes CVE-2026-75759, as eh_os_contract_auth pins it.
      {:oidcc, "~> 3.9"},
      # `ehosctl logs --follow` reads EHOS's tail as server-sent events (eh-os D-97), through Req,
      # which hands over each part as it comes (`Ehosctl.HTTP.stream/5`).
      {:server_sent_events, "~> 1.1"},
      {:req, "~> 0.7"},
      # Finch, under Req, says by telemetry when a connection could not be made: a request that
      # never had one was never sent (`Ehosctl.HTTP.request/5`).
      {:telemetry, "~> 1.0"},
      # A fake provider on a local port, for oidcc's `httpc` to talk to in tests.
      {:bypass, "~> 2.1", only: :test},
      # Needed in :test too, since `mix check` runs there and builds the documentation.
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: :test, runtime: false},
      {:dialyxir, "~> 1.4", only: :test, runtime: false}
    ]
  end

  # The PLTs live in `_build/`, which CI caches. `mix ehosctl.release_file` is a Mix task, so Mix
  # is in the PLT, and ExUnit too, since `test/support` is compiled in `test`, where this runs.
  defp dialyzer,
    do: [
      plt_core_path: "_build/plts",
      plt_local_path: "_build/plts",
      plt_add_apps: [:mix, :ex_unit]
    ]

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
