defmodule Ehosctl.MixProject do
  use Mix.Project

  # The next minor version with `-dev` between releases; only a release's pull request sets a
  # plain one (eh-os D-91, https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md).
  @version "0.55.0-dev"

  # The pages of `docs/commands/`, in the order the reference lists them: how a command answers
  # first, then the local commands, signing in, the governed commands, and the platform's last.
  @command_pages ~w(output init installations login apps call people agreements deploy builds promotions env
                    env-quota env-template secrets db role-bindings github-actions audit verify
                    status domains versions server install upgrade add-database server-invite
                    server-admin server-rotate-client-ca server-handover)

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
      package: [licenses: ["Apache-2.0"]],
      name: "ehosctl",
      source_url: "https://github.com/EmpoweredHouse/ehos-tools",
      docs: docs()
    ]
  end

  # Credo and Dialyzer are test-only dependencies, so `mix check`, `mix credo` and `mix dialyzer`
  # run in `test`, where they are.
  def cli, do: [preferred_envs: [check: :test, credo: :test, dialyzer: :test]]

  # A fake EHOS and a fake keychain, for the tests of signing in, and the repository's
  # conventions case every package's tests share (ehos-tools#690), by an absolute path, since Mix
  # reads a relative one as inside the project.
  defp elixirc_paths(:test),
    do: ["lib", "test/support", Path.expand("../../test/support", __DIR__)]

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
        # passes dialyxir's check while it holds an older `ehos_platform`, and a module added to
        # it since reads as unknown (ehos-tools#542). `--force-check` compares the PLT with the
        # beams.
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
      extras:
        ["README.md" | Enum.map(@command_pages, &"docs/commands/#{&1}.md")] ++ ["CHANGELOG.md"],
      groups_for_extras: [Commands: ~r{^docs/commands/}],
      # The fakes and cases the tests share are compiled in `test`, where the gate builds this,
      # and are no part of what ehosctl is. A way out's moduledoc still names the case its tests
      # start from, as text.
      filter_modules: fn _module, %{source_path: path} ->
        not String.contains?(to_string(path), "/test/support/")
      end,
      skip_code_autolink_to: ["Ehosctl.Case", "Ehosctl.Case.stub_virtual_clock/0"],
      groups_for_modules: [
        "Command line": [
          Ehosctl,
          Ehosctl.Application,
          Ehosctl.CLI,
          Ehosctl.Command,
          Ehosctl.Failure,
          Ehosctl.Output,
          Ehosctl.PlatformReport,
          Ehosctl.Refusal,
          Ehosctl.Notice
        ],
        "Local commands": [
          Ehosctl.Init,
          Ehosctl.InitService,
          Ehosctl.Template,
          Ehosctl.Mise,
          Ehosctl.Installations
        ],
        "Signing in": [
          Ehosctl.Config,
          Ehosctl.Login,
          Ehosctl.Logout,
          Ehosctl.Whoami,
          Ehosctl.Terminals,
          Ehosctl.SignIn,
          Ehosctl.SignIn.Loopback,
          Ehosctl.SignIn.Page,
          Ehosctl.Credentials,
          Ehosctl.Credential,
          Ehosctl.GitHubActions,
          Ehosctl.TokenStore,
          Ehosctl.TokenStore.Keychain,
          Ehosctl.TokenStore.SecretService,
          Ehosctl.TokenStore.File,
          Ehosctl.FileLock,
          Ehosctl.PrivateFile,
          Ehosctl.TLS
        ],
        "Governed commands": [
          Ehosctl.Roles,
          Ehosctl.Apps,
          Ehosctl.DeploymentHistory,
          Ehosctl.Call,
          Ehosctl.People,
          Ehosctl.Agreements,
          Ehosctl.Mail,
          Ehosctl.Services,
          Ehosctl.Deploy,
          Ehosctl.Builds,
          Ehosctl.Promotions,
          Ehosctl.Promote,
          Ehosctl.Approve,
          Ehosctl.Refuse,
          Ehosctl.Landscape,
          Ehosctl.Graph,
          Ehosctl.Db,
          Ehosctl.DataCa,
          Ehosctl.DataSession,
          Ehosctl.Postgres,
          Ehosctl.Tunnel,
          Ehosctl.SessionSecrets,
          Ehosctl.Scram,
          Ehosctl.SessionFiles,
          Ehosctl.Env,
          Ehosctl.EnvQuota,
          Ehosctl.EnvTemplates,
          Ehosctl.TemplateEntries,
          Ehosctl.TemplateServiceEntries,
          Ehosctl.Secrets,
          Ehosctl.SecretInput,
          Ehosctl.Resources,
          Ehosctl.RoleBindings,
          Ehosctl.Trusts,
          Ehosctl.GitHubAccounts,
          Ehosctl.Logs,
          Ehosctl.Audit,
          Ehosctl.Activity,
          Ehosctl.Agents,
          Ehosctl.Verify,
          Ehosctl.Status,
          Ehosctl.InstallationDomain,
          Ehosctl.Domains,
          Ehosctl.Versions,
          Ehosctl.Changelog
        ],
        "EHOS's API": [
          Ehosctl.Api,
          Ehosctl.AtCount,
          Ehosctl.Pages,
          Ehosctl.Deployments,
          Ehosctl.Review,
          Ehosctl.PromotionReview,
          Ehosctl.Source,
          Ehosctl.ManifestFile,
          Ehosctl.Bundle,
          Ehosctl.ServiceYaml,
          Ehosctl.ServiceYaml.Reader,
          Ehosctl.ServiceYaml.Schema,
          Ehosctl.Multipart,
          Ehosctl.Checkout,
          Ehosctl.Project
        ],
        "Platform commands": [
          Ehosctl.Doctor,
          Ehosctl.Server,
          Ehosctl.ServerAdmin,
          Ehosctl.ServerRotateClientCa,
          Ehosctl.ServerHandover,
          Ehosctl.Install,
          Ehosctl.Upgrade,
          Ehosctl.ResourcesAddDatabase,
          Ehosctl.ResourcesMarkGone,
          Ehosctl.ResourcesRemoveDatabase,
          Ehosctl.ExternalDatabaseList,
          Ehosctl.ResourcesPrepareSql,
          Ehosctl.PlatformRunner,
          Ehosctl.EhosRelease,
          Ehosctl.ServerRelease
        ],
        "Versions and releases": [
          Ehosctl.Acceptance,
          Ehosctl.GitHub,
          Ehosctl.ReleaseNotes,
          Ehosctl.Version,
          Ehosctl.Build,
          Mix.Tasks.Ehosctl.ReleaseFile
        ],
        # T-20: each way out, its behaviour and the implementation beside it.
        "Ways out": [
          Ehosctl.Browser,
          Ehosctl.BrowserImpl,
          Ehosctl.Clock,
          Ehosctl.ClockImpl,
          Ehosctl.HTTP,
          Ehosctl.HTTPImpl,
          Ehosctl.OS,
          Ehosctl.OSImpl,
          Ehosctl.Runner,
          Ehosctl.RunnerImpl,
          Ehosctl.ServerAdministrators,
          Ehosctl.ServerAdministratorsImpl,
          Ehosctl.SignInImpl,
          Ehosctl.SystemEnv,
          Ehosctl.SystemEnvImpl,
          Ehosctl.SystemKeychain,
          Ehosctl.SystemKeychainImpl,
          Ehosctl.Terminal,
          Ehosctl.TerminalImpl
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
      # The wire to the data gateway, which a data session's tunnels use (eh-os D-180).
      {:ehos_tunnel, path: "../ehos_tunnel"},
      # T-09: signing in is oidcc's, the library EHOS's provider is tested against. 3.9.0 is
      # the first that fixes CVE-2026-75759, as ehos_contract_auth pins it.
      {:oidcc, "~> 3.9"},
      # `ehosctl logs --follow` reads EHOS's tail as server-sent events (eh-os D-97), through Req,
      # which hands over each part as it comes (`Ehosctl.HTTP.stream/5`).
      {:server_sent_events, "~> 1.1"},
      {:req, "~> 0.7"},
      # Finch, under Req, says by telemetry when a connection could not be made: a request that
      # never had one was never sent (`Ehosctl.HTTP.request/5`).
      {:telemetry, "~> 1.0"},
      # A utility service's `ehos.yaml` is read as EHOS reads it (eh-os D-51), with the libraries
      # and the version of JSV that EHOS uses, so a file is refused for the same reasons
      # (`Ehosctl.ServiceYaml`): yamerl's parser shows the anchors, aliases and tags that are
      # refused, and JSV implements the schema's draft 2020-12.
      {:yamerl, "~> 0.10"},
      {:jsv, "~> 0.26.2"},
      # EEF-CVE-2026-117678: idna before 8.0.0 Punycode-decodes a label before it checks the
      # 63-octet limit, so one long label costs seconds of CPU (ehos-tools#1000). JSV and
      # public_sufx (through ehos_platform) still ask for idna 7, and work with 8; this goes once
      # both allow 8.
      {:idna, "~> 8.0", override: true},
      # A fake provider on a local port, over https, for oidcc's `httpc` to talk to in tests.
      {:bandit, "~> 1.12", only: :test},
      {:hammox, "~> 1.0", only: :test},
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
