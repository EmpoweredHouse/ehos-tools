defmodule Ehosctl.MixProject do
  use Mix.Project

  @version "0.1.2"

  def project do
    [
      app: :ehosctl,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      releases: releases(),
      deps: deps()
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application do
    [extra_applications: [:logger], mod: {Ehosctl.Application, []}]
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
      {:burrito, "~> 1.6"}
    ]
  end
end
