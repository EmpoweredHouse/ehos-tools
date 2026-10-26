defmodule EhosDesign.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  @version "0.5.0-dev"

  def project do
    [
      app: :ehos_design,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # LiveView's compiler writes the manifest of the colocated hook `EhosDesign.Components`
      # carries, `phoenix-colocated/ehos_design`, which a host imports (eh-os D-86).
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      package: [licenses: ["Apache-2.0"]]
    ]
  end

  # LiveView is required, not optional: the colocated hook needs its compiler in this project's
  # `compilers`, which a host without it could not run. Every host that takes the package from
  # Mix is a Phoenix application, with LiveView already.
  defp deps do
    [
      {:phoenix_live_view, "~> 1.1"},
      # EhosDesign.Mail (eh-os D-122): premailex moves the mail's stylesheet into inline styles,
      # reading the HTML with Floki, which is plain Elixir and which the package names as the
      # parser, so a host's LazyHTML does not write the HTML out differently.
      {:premailex, "~> 1.0"},
      {:floki, "~> 0.38"},
      {:lazy_html, "~> 0.1", only: :test},
      # The browser test of the keyboard (test/browser): a page served by Bandit, its script
      # bundled by esbuild, driven by Playwright.
      {:phoenix_test_playwright, "~> 0.18.0", only: :test, runtime: false},
      {:bandit, "~> 1.12", only: :test},
      {:esbuild, "~> 0.10.0", only: :test}
    ]
  end

  # On CI, a fresh Linux runner, Playwright also installs the libraries the browser needs.
  defp browser_setup(_args) do
    deps = if System.get_env("CI"), do: ["--with-deps"], else: []

    for args <- [
          # No package's install script runs: the browser is the next command's to fetch.
          ~w(ci --ignore-scripts --prefix test/browser),
          ~w(exec --prefix test/browser -- playwright install) ++ deps ++ ["chromium"]
        ] do
      {_, 0} = System.cmd("npm", args, into: IO.stream())
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def cli, do: [preferred_envs: [check: :test]]

  # An application with no processes: it is one so that a release carries its `priv/`, and a
  # host serves the fonts with `Plug.Static, from: {:ehos_design, "priv/static"}`.
  def application, do: []

  defp aliases do
    [
      "ehos_design.release_file": &release_file/1,
      # Playwright and its browser, for the browser test, once per machine.
      "browser.setup": &browser_setup/1,
      check: [
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "test --include browser_test"
      ]
    ]
  end

  # `mix ehos_design.release_file --commit <sha> [--output <path>]`: the release's `release.json`, from
  # `EhosDesign.release/1` (eh-os D-91), for the release workflow. An alias, not a task, so that a
  # project depending on this package does not get it.
  defp release_file(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [commit: :string, output: :string])
    commit = opts[:commit]

    unless rest == [] and is_binary(commit) and commit =~ ~r/\A[0-9a-f]{40}\z/ do
      Mix.raise("Usage: mix ehos_design.release_file --commit <full sha> [--output <path>]")
    end

    Mix.Task.run("compile")
    :ok = Application.ensure_loaded(:ehos_design)
    output = Keyword.get(opts, :output, "release.json")
    # Called through apply/3: the module is the package's, compiled after this file.
    File.write!(output, [JSON.encode!(apply(EhosDesign, :release, [commit])), ?\n])
    Mix.shell().info("wrote #{output}")
  end
end
