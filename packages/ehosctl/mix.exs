defmodule Ehosctl.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  @version "0.3.0-dev"

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
      name: "ehosctl",
      source_url: "https://github.com/EmpoweredHouse/ehos-tools",
      docs: docs()
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  # A fake EHOS and a fake keychain, for the tests of signing in.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [extra_applications: [:logger, :crypto], mod: {Ehosctl.Application, []}]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "test",
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
        Configuration: [Ehosctl.Config, Ehosctl.PrivateFile, Ehosctl.Template, Ehosctl.Version]
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
      # T-09: signing in is oidcc's, the library EHOS's provider is tested against. 3.9.0 is
      # the first that fixes CVE-2026-75759, as eh_os_contract_auth pins it.
      {:oidcc, "~> 3.9"},
      # A fake provider on a local port, for oidcc's `httpc` to talk to in tests.
      {:bypass, "~> 2.1", only: :test},
      # Needed in :test too, since `mix check` runs there and builds the documentation.
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false}
    ]
  end
end
