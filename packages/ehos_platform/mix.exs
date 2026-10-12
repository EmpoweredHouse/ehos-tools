defmodule EhosPlatform.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  @version "0.3.0-dev"

  def project do
    [
      app: :ehos_platform,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
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
      {:mox, "~> 1.2", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def cli, do: [preferred_envs: [check: :test]]

  # An application with no processes: it is one so that a release carries its `priv/`, the
  # manifests the installer applies.
  def application, do: [extra_applications: [:crypto]]

  defp aliases do
    [
      "ehos_platform.release_file": &release_file/1,
      check: [
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "test"
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
    File.write!(output, [JSON.encode!(apply(EhosPlatform, :release, [commit])), ?\n])
    Mix.shell().info("wrote #{output}")
  end
end
