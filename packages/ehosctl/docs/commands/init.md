# `ehosctl init <name>`

`<name>` becomes the OTP application's name. It is lowercase letters, digits and underscores,
starts with a letter and ends with a letter or a digit. A dash is written as an underscore, since
an OTP application's name allows none, and `init` says so: `ehosctl init my-shop` generates
`my_shop/`. In EHOS the application is named with dashes, as its domain is: `my-shop`. `init`
refuses a directory that already exists.

What it runs, in order. Each step gets the terminal's own stdin, stdout and stderr, so a step that
asks a question can be answered and errors stay on stderr. Each Mix step runs under
`mise exec erlang@<pin> elixir@<pin> --`, and `mise install` and every Mix step with
`MISE_ACTIVATE_AGGRESSIVE=1`, so that the pinned versions come first on the `PATH` even where
asdf's shims come before mise's
([With asdf](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/README.md#with-asdf)
says what that means for the generated project):

0. `mise install erlang@<pin> elixir@<pin>`, which does nothing once they are installed. Without
   it, `mise exec` would have to install a missing Elixir itself, and it runs the new Elixir's
   check without the Erlang named next to it on the path, so it fails with `erl: not found`.
1. `mix local.hex`, `mix archive.install hex phx_new <pin>` and
   `mix archive.install hex igniter_new <pin>`. These go into a directory that belongs to this
   `ehosctl` version, not your `~/.mix`, and are skipped when already there.
2. `mix igniter.new <name> --with phx.new --with-args "--database postgres" --yes --no-git`,
   which creates the Phoenix project.
3. In `<name>/`, `mix run --no-start -e '… Igniter.Util.Install.install([<ehos_app>], ["--example", "--yes"])'`,
   which adds [`ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_app/README.md) from `packages/ehos_app` of ehos-tools at the
   pinned commit and runs its installer, and Oban's with it. `mix igniter.new --install` would be
   simpler, but its spec cannot name a subdirectory.
4. `mix local.hex --if-missing`, for the pinned Elixir, so the project's own first `mix` command
   does not stop to ask for Hex.
5. `mise trust <name>/.tool-versions`, so `cd <name>` puts the pinned toolchain on the path.
6. `mix format` in `<name>/`, since `phx.new` leaves a test unformatted once the module's name has
   11 characters or more, and CI's first run would fail its format gate
   ([#574](https://github.com/EmpoweredHouse/ehos-tools/issues/574)).
7. `git init`, `git symbolic-ref HEAD refs/heads/main`, `git add --all` and `git commit` in
   `<name>/`: the project's first commit, of everything above, on `main`, the branch its CI
   publishes from, whatever git's own default branch is (`phx.new` has already run `git init`,
   which a second `git init --initial-branch=main` would not change).

On the machine it was measured on (macOS arm64, Hex packages already cached), `init` took 80–85
seconds, most of it fetching and compiling dependencies. The first `mise exec` of a toolchain adds
about 10 seconds, since mise installs precompiled builds.

## What it pins

All of it is in [`lib/ehosctl/template.ex`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/lib/ehosctl/template.ex). One release of `ehosctl`
always generates the same project:

| Pin | Value |
| --- | --- |
| Erlang | 28.5.0.7 |
| Elixir | 1.20.4-otp-28 |
| `phx_new` | 1.8.14 |
| `igniter_new` | 0.5.34 |
| `ehos_app` | [`packages/ehos_app`](https://github.com/EmpoweredHouse/ehos-tools/tree/ca27de4b3c933e80a545f8289511bb861e141f7c/packages/ehos_app) of ehos-tools at `ca27de4`, the commit the tag `ehos_app-v0.22.0` names |
| `eh_os_contract` | 0.12.0, which `ehos_app` 0.22.0 pins ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md)) |

## Where it writes

| What | macOS | Linux |
| --- | --- | --- |
| The new project | `./<name>` | `./<name>` |
| Installations (`config.json`) | `~/.config/ehosctl` | `$XDG_CONFIG_HOME/ehosctl`, by default `~/.config/ehosctl` |
| Sign-ins | the login keychain, and `~/.local/state/ehosctl` | the Secret Service, and `$XDG_STATE_HOME/ehosctl`, by default `~/.local/state/ehosctl` |
| Generator archives | `~/Library/Caches/ehosctl/<version>/mix_archives` | `$XDG_CACHE_HOME/ehosctl/<version>/mix_archives`, by default under `~/.cache` |
| The update notice's cache (`notice.json`) | `~/Library/Caches/ehosctl` | `$XDG_CACHE_HOME/ehosctl`, by default `~/.cache/ehosctl` |
| Erlang and Elixir | wherever mise installs tools (`~/.local/share/mise` by default) | the same |
| The unpacked `ehosctl` runtime | `~/Library/Application Support/.burrito/` | `$XDG_DATA_HOME/.burrito/`, by default under `~/.local/share` |

`ehosctl maintenance uninstall` removes the unpacked runtime. `EHOSCTL_INSTALL_DIR` moves it.
