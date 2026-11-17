defmodule EhosTunnel.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  @version "0.2.0-dev"

  def project do
    [
      app: :ehos_tunnel,
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

  # The data tunnel's wire, which the data gateway, eh-os's tests and `ehosctl` share (eh-os
  # D-180): Erlang's `:public_key`, `:ssl` and `:crypto`, and Mint's WebSocket client, with
  # nothing of EHOS's or Phoenix's.
  defp deps do
    [
      {:mint, "~> 1.7"},
      {:mint_web_socket, "~> 1.0"},
      # The test gateway the client's tests tunnel through: a WebSocket server with TLS client
      # authentication.
      {:bandit, "~> 1.6", only: :test},
      {:websock_adapter, "~> 0.5", only: :test},
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

  # No processes of its own: a client's listener and tunnels run under its caller.
  def application, do: [extra_applications: [:crypto, :public_key, :ssl]]

  defp aliases do
    [
      "ehos_tunnel.release_file": &release_file/1,
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
        "https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_tunnel/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md"],
      # The repository's conventions case and the test gateway are compiled in `test`, where the
      # gate builds this, and are no part of what the package is (ehos-tools#690).
      filter_modules: fn _module, %{source_path: path} ->
        not String.contains?(to_string(path), "/test/support/")
      end,
      groups_for_modules: [
        "The wire": [EhosTunnel.Key, EhosTunnel.Certificate, EhosTunnel.Protocol],
        "The client": [EhosTunnel.Client, EhosTunnel.ClientImpl]
      ]
    ]
  end

  # `mix ehos_tunnel.release_file --commit <sha> [--output <path>]`: the release's
  # `release.json`, from `EhosTunnel.release/1` (eh-os D-91), for the release workflow. An alias,
  # not a task, so that a project depending on this package does not get it.
  defp release_file(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [commit: :string, output: :string])
    commit = opts[:commit]

    unless rest == [] and is_binary(commit) and commit =~ ~r/\A[0-9a-f]{40}\z/ do
      Mix.raise("Usage: mix ehos_tunnel.release_file --commit <full sha> [--output <path>]")
    end

    Mix.Task.run("compile")
    :ok = Application.ensure_loaded(:ehos_tunnel)
    output = Keyword.get(opts, :output, "release.json")
    # Called through apply/3: the module is the package's, compiled after this file.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    File.write!(output, [JSON.encode!(apply(EhosTunnel, :release, [commit])), ?\n])
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
