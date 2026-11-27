# `ehosctl init NAME`

`ehosctl init NAME` creates a new EHOS application in the directory `NAME`, from the application
template. `ehosctl init --service NAME` writes the files of a utility service into the current
directory ([Start a utility service](#start-a-utility-service)). This page is for a developer who
starts an application or a utility service. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

## Choose the name

`NAME` becomes the name of the OTP application.

- Use lowercase letters, digits and underscores.
- Start with a letter, and end with a letter or a digit.
- The name of an OTP application has no dash, so `init` writes a dash as an underscore, and says so:
  `ehosctl init my-shop` generates `my_shop/`.
- In EHOS, the application has dashes in its name, as its domain does: `my-shop`.

`init` refuses a directory that already exists.

## What init runs

`init` says each step on stderr, after `==>`. What the step prints follows that line on stderr,
indented, as the step prints it. Each step keeps the stdin of the terminal, so you can answer a
step that asks a question. A program that asks only when its output is a terminal, as mise does
before it trusts a file, does not ask, and the step fails. When every step passes, stdout holds the
outcome: the directory, the Erlang and Elixir, the name in EHOS, a reminder to start Docker, and
`cd NAME` and `mix setup` under `Next:`. When a step fails, `init` names the command that failed.
When the step leaves something behind, `init` says what, and what to do. Each Mix step runs under
`mise exec erlang@<pin> elixir@<pin> --`. `mise install` and each Mix step run with
`MISE_ACTIVATE_AGGRESSIVE=1`. So the pinned versions come first on the `PATH`, also where the shims
of asdf come before the shims of mise.
[With asdf](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/README.md#with-asdf)
says what that means for the generated project.

0. `mise install erlang@<pin> elixir@<pin>`. This does nothing when they are installed. Without it,
   `mise exec` must install a missing Elixir itself. It runs the check of the new Elixir without the
   Erlang named next to it on the path, so it fails with `erl: not found`.
1. `mix local.hex`, `mix archive.install hex phx_new <pin>` and
   `mix archive.install hex igniter_new <pin>`. These go into a directory of this version of
   `ehosctl`, not into your `~/.mix`. `init` skips them when they are there.
2. `mix igniter.new NAME --with phx.new --with-args "--database postgres" --yes --no-git`, which
   creates the Phoenix project.
3. In `NAME/`, `elixir -e '…'` and `mix deps.update igniter`. `igniter.new` lets the project take
   the newest Igniter, and `ehos_app` and `oidcc` require Igniter below 0.9. So `init` changes
   the requirement on Igniter in `mix.exs` to the pinned one, and moves the lock to it.
4. In `NAME/`,
   `mix run --no-start -e '… Igniter.Util.Install.install([<ehos_app>], ["--example", "--yes"])'`.
   This adds
   [`ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_app/README.md)
   from `packages/ehos_app` of ehos-tools, at the pinned commit. It runs its installer, and the
   installer of Oban with it. `mix igniter.new --install` cannot name a subdirectory, so `init` does
   not use it.
5. `mix local.hex --if-missing`, for the pinned Elixir. So the first `mix` command of the project
   does not stop to ask for Hex.
6. `mise trust NAME/.tool-versions`. So `cd NAME` puts the pinned toolchain on the path.
7. `mix format` in `NAME/`. `phx.new` leaves a test unformatted when the name of the module has 11
   characters or more. The first run of CI would then fail its format check.
8. `git init`, `git symbolic-ref HEAD refs/heads/main`, `git add --all` and `git commit` in
   `NAME/`. This is the first commit of the project, of all the above, on `main`. CI publishes
   from `main`, whatever the default branch of git is. `phx.new` has already run `git init`, and a
   second `git init --initial-branch=main` does not change the branch.

## How long init takes

On the machine of the measurement (macOS arm64, with the Hex packages in the cache), `init` took 80
to 85 seconds. Most of the time goes to fetching and compiling dependencies. The first `mise exec`
of a toolchain adds about 10 seconds, because mise installs precompiled builds.

## What it pins

[`lib/ehosctl/template.ex`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/lib/ehosctl/template.ex)
holds all the pins. So one release of `ehosctl` always generates the same project:

| Pin | Value |
| --- | --- |
| Erlang | 28.5.0.7 |
| Elixir | 1.20.4-otp-28 |
| `phx_new` | 1.8.14 |
| `igniter_new` | 0.5.34 |
| `igniter` | ~> 0.8.6, the requirement that `init` gives the project |
| `ehos_app` | [`packages/ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/tree/cf885ec8e13bd2d6145ae7f8bf0c4ee6fa928c6c/packages/ehos_app) of ehos-tools at `cf885ec`, the commit the tag `ehos_app-v0.39.0` names |
| `ehos_contract` | 0.17.0, which `ehos_app` 0.39.0 pins ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md)) |

## Where it writes

| What | macOS | Linux |
| --- | --- | --- |
| The new project | `./NAME` | `./NAME` |
| Installations (`config.json`) | `~/.config/ehosctl` | `$XDG_CONFIG_HOME/ehosctl`, by default `~/.config/ehosctl` |
| Sign-ins | the login keychain, and `~/.local/state/ehosctl` | the Secret Service, and `$XDG_STATE_HOME/ehosctl`, by default `~/.local/state/ehosctl` |
| Generator archives | `~/Library/Caches/ehosctl/<version>/mix_archives` | `$XDG_CACHE_HOME/ehosctl/<version>/mix_archives`, by default under `~/.cache` |
| The update notice's cache (`notice.json`) | `~/Library/Caches/ehosctl` | `$XDG_CACHE_HOME/ehosctl`, by default `~/.cache/ehosctl` |
| Erlang and Elixir | wherever mise installs tools (`~/.local/share/mise` by default) | the same |
| The unpacked `ehosctl` runtime | `~/Library/Application Support/.burrito/` | `$XDG_DATA_HOME/.burrito/`, by default under `~/.local/share` |

`ehosctl maintenance uninstall` removes the unpacked runtime. `EHOSCTL_INSTALL_DIR` moves it.

## Start a utility service

A utility service is a program with no contract, in any language, that the applications of an
environment share. Its repository has no Elixir project. Run `init --service` in that repository:

```sh
cd invoice-pdf
ehosctl init --service invoice-pdf --port 8080 --memory 512Mi
```

`NAME` is the name of the utility service in EHOS: lowercase letters, digits and dashes. `init`
writes two files:

- **`ehos.yaml`**, with `kind: service`, the name, the port of the API, the port and paths of the
  health check, and the memory. `init` checks the file as EHOS reads it before it writes it. If
  EHOS would refuse a value, `init` names the option and the reason, writes nothing, and exits
  with 2.
- **`.github/workflows/ehos.yml`**, the pipeline. It calls the shared workflow of ehos-tools,
  `ehos-service.yml`, at the commit that the tag of this release of `ehosctl` names, with the tag
  beside it. That workflow installs the `ehosctl` of the same release
  ([The pipeline of a utility service](#the-pipeline-of-a-utility-service)).

| Option | Value | Default |
| --- | --- | --- |
| `--port` | The port of the API, from 1024 | `8080` |
| `--health-port` | The port of the health check, from 1024 | `8081` |
| `--ready` | The path that answers when the service is ready | `/ready` |
| `--live` | The path that answers while the service is alive | `/live` |
| `--memory` | The memory the service needs | `256Mi` |

If you do not give an option and `init` runs at a terminal, `init` asks for the value. Press Enter
to take the default. Elsewhere, `init` takes the default.

`init` does not overwrite a file. If `ehos.yaml` or the pipeline exists, `init` keeps it and says
so. If `ehos.yaml` exists, `init` asks for no value. So you can run `init --service` again to add
a file that you removed. `init` refuses a directory that holds `mix.exs`, because that is the
directory of an application. It also refuses a `.github` or `.github/workflows` that is a link,
because it writes no file outside the repository. Without `--service`, `init` refuses the options
of a utility service.

`init` writes no `Dockerfile`, because the language of the service is your choice. EHOS runs the
image as it is. Make sure that the image:

- runs as a user that is not root,
- listens on the ports in `ehos.yaml`,
- reads its settings from environment variables,
- writes its logs to standard output.

Then run `ehosctl verify` in the same directory ([Checking an application](verify.md)).

### The pipeline of a utility service

The shared workflow runs on each push to `main` and on each pull request. It does these steps:

1. It runs `ehosctl verify`, which checks `ehos.yaml` and writes the bundle.
2. It builds the image from the `Dockerfile` of the repository, for amd64 and arm64.
3. It registers the build with the installation that the repository variable `EHOSCTL_URL`
   names. It does this from a pull request of the repository, unless a bot started the run. It
   does this from `main` once the trust of EHOS accepts `refs/heads/main`. If the trust refuses
   the run, the summary of the run says what to do.
4. If the repository variable `EHOS_PREVIEWS` is `true`, it deploys the build of a pull request to
   an ephemeral environment of its own. When a person closes the pull request without a merge, it
   removes the environment. Otherwise the environment expires 8 hours after the last push.

Before the pipeline registers a build, do these steps once:

1. Register the utility service: `ehosctl apps register ehos.yaml`. This needs
   `ehos.application.register` on the platform.
2. Let EHOS trust the repository: `ehosctl trusts add --app <service> --repo <owner/name> --ref
   'refs/pull/*/merge'`. Do not name a workflow in the trust. EHOS refuses a run of a workflow that
   the repository calls from another repository under a trust that names one.
3. Set the repository variable `EHOSCTL_URL` to the address of the installation. If the
   installation has its own CA, set `EHOSCTL_CA_PEM` to its certificate.

To register a build from a pull request, the person who pushes needs `ehos.application.deploy` on
the utility service, and their GitHub account must be linked to them in EHOS. A preview also needs
`ehos.application.register`.

To move to a later pipeline, change the commit and the tag in `ehos.yml` to those of a later
release of `ehosctl`. Never name a branch there.

## Next steps

- [Sign in](login.md)
- [Deploy from GitHub Actions](github-actions.md)
