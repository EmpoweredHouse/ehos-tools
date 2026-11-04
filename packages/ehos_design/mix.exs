defmodule EhosDesign.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  @version "0.6.0-dev"

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
      dialyzer: dialyzer(),
      package: [licenses: ["Apache-2.0"]],
      source_url: "https://github.com/EmpoweredHouse/ehos-tools",
      docs: docs()
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
      {:esbuild, "~> 0.10.0", only: :test},
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

  # The repository's conventions case every package's tests share (ehos-tools#690), by an
  # absolute path, since Mix reads a relative one as inside the project.
  defp elixirc_paths(:test),
    do: ["lib", "test/support", Path.expand("../../test/support", __DIR__)]

  defp elixirc_paths(_env), do: ["lib"]

  # Credo and Dialyzer are test-only dependencies, so a tool that runs this package in `dev`
  # (the review gate's hook, the `review section` workflow) needs no `deps.get` for them.
  def cli, do: [preferred_envs: [check: :test, credo: :test, dialyzer: :test]]

  # An application with no processes: it is one so that a release carries its `priv/`, and a
  # host serves the fonts and the icon with `Plug.Static, from: {:ehos_design, "priv/static"}`.
  def application, do: []

  defp aliases do
    [
      "ehos_design.release_file": &release_file/1,
      # Playwright and its browser, for the browser test, once per machine.
      "browser.setup": &browser_setup/1,
      # The repository's `.credo.exs`, whichever way Credo is run (`.credo.exs` says why).
      credo: "credo --config-file ../../.credo.exs",
      check: [
        &hex_audit/1,
        "format --check-formatted",
        "compile --force --warnings-as-errors",
        "credo",
        "test --include browser_test --warnings-as-errors",
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
        "https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_design/%{path}#L%{line}",
      extras: ["README.md", "CHANGELOG.md"],
      # The repository's conventions case is compiled in `test`, where the gate builds this, and
      # is no part of what the package is (ehos-tools#690).
      filter_modules: fn _module, %{source_path: path} ->
        not String.contains?(to_string(path), "/test/support/")
      end,
      groups_for_modules: [
        Components: [EhosDesign.Components],
        Mail: [EhosDesign.Mail, EhosDesign.Mail.Theme, EhosDesign.Mail.Stylesheet]
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
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    File.write!(output, [JSON.encode!(apply(EhosDesign, :release, [commit])), ?\n])
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
