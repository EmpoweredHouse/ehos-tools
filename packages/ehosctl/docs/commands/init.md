# `ehosctl init NAME`

`ehosctl init NAME` creates a new EHOS application in the directory `NAME`, from the application
template. This page is for a developer who starts an application. The
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

Each step gets the stdin, stdout and stderr of the terminal. So you can answer a step that asks a
question, and errors stay on stderr. Each Mix step runs under
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
3. In `NAME/`,
   `mix run --no-start -e '… Igniter.Util.Install.install([<ehos_app>], ["--example", "--yes"])'`.
   This adds
   [`ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_app/README.md)
   from `packages/ehos_app` of ehos-tools, at the pinned commit. It runs its installer, and the
   installer of Oban with it. `mix igniter.new --install` cannot name a subdirectory, so `init` does
   not use it.
4. `mix local.hex --if-missing`, for the pinned Elixir. So the first `mix` command of the project
   does not stop to ask for Hex.
5. `mise trust NAME/.tool-versions`. So `cd NAME` puts the pinned toolchain on the path.
6. `mix format` in `NAME/`. `phx.new` leaves a test unformatted when the name of the module has 11
   characters or more. The first run of CI would then fail its format check.
7. `git init`, `git symbolic-ref HEAD refs/heads/main`, `git add --all` and `git commit` in
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
| `ehos_app` | [`packages/ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/tree/df9eb4a8e4f1f340cf013669f7362cdfcdcb1bd2/packages/ehos_app) of ehos-tools at `df9eb4a`, the commit the tag `ehos_app-v0.29.0` names |
| `eh_os_contract` | 0.13.1, which `ehos_app` 0.29.0 pins ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md)) |

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

## Next steps

- [Sign in](login.md)
- [Deploy from GitHub Actions](github-actions.md)
