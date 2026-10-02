# ehos-tools

`ehosctl`, the command-line tool for EHOS, `ehos_app`, the template it creates applications
from, and `ehos_design`, the design system those applications are styled from by default. This
repository is meant to be open-sourced: it has to make sense to someone who was not in the room
when it was built, so write every file for that reader.

## Start here

| Question | Where the answer is |
| --- | --- |
| What is this and why does it exist? | `README.md` |
| What works, what was measured, what is still open? | `docs/spike.md`: read it before changing anything |
| Why this stack (Burrito, Igniter, mise, a Homebrew tap)? | `docs/research.md` |
| How must code, tests, commits and versions look? | `CONTRIBUTING.md`, binding for agents as well as people |
| What does EHOS require of an application? | The EHOS specification: [ARCHITECTURE.md](https://github.com/empoweredhouse/eh-os/blob/main/docs/ARCHITECTURE.md) (§2 and §5.1 for `ehos.yaml`) and [ROADMAP.md](https://github.com/empoweredhouse/eh-os/blob/main/docs/ROADMAP.md) (Stages 5–7) |
| How is a contract written? | [`eh_os_contract`'s contract.md](https://github.com/empoweredhouse/eh-os-contract/blob/main/packages/eh_os_contract/docs/contract.md) |

## How the pieces fit

```text
ehosctl init shop
  └─ mise exec erlang@<pin> elixir@<pin> --        (Ehosctl.Init, pins in Ehosctl.Template)
       ├─ mix archive.install … phx_new, igniter_new   into ehosctl's own archives directory
       └─ mix igniter.new shop --with phx.new --install ehos_app@<pin>
            └─ mix ehos_app.install                    (packages/ehos_app)
                 ├─ oban.install                        Oban's own installer
                 ├─ eh_os_contract, eh_os_contract_auth deps, config, migrations, supervision children
                 ├─ health, ehos.yaml + EHOS's schema, runtime config from EHOS's variables
                 ├─ .tool-versions, CI workflow
                 ├─ the agent harness: AGENTS.md, VISION.md and the other docs, skills,
                 │  test/harness_test.exs, then ehos_app.link_skills (the symlinks)
                 └─ phx.gen.release, then ehos_app.dockerfile (the build secret)
```

`ehosctl` installs `ehos_app` from this repository, as `packages/ehos_app` at an `ehos_app-v*`
tag, through `Igniter.Util.Install.install/2` in the new project (`Ehosctl.Template`).

- `packages/ehosctl` is a Burrito release. `Ehosctl.Application` runs the command and halts the VM.
  `Ehosctl.CLI` dispatches on argv and returns an exit code. Each command is its own module, which
  builds its steps as data first and runs them second, so tests can read what it would do.
- `packages/ehos_design` is the EmpoweredHouse design system as files: tokens copied from Claude
  Design (never edited here; refresh them with the `sync-design-system` skill), a layer for
  Tailwind and daisyUI, and the fonts. It has no code, and it is released by its own tags,
  `ehos_design-v*` ([eh-os D-72](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0072-the-design-system-is-a-library-ehos-design-kept-in-ehos-tools.md)).
- `packages/ehos_app` is an Igniter installer. `Mix.Tasks.EhosApp.Install` holds the logic, and the
  files it writes are EEx templates under `priv/templates/ehos_app.install/`.
- EHOS itself is not a dependency of any package. What the template says about EHOS comes from
  its specification, and whatever EHOS has not decided yet is listed in `docs/spike.md` as a guess.

## Rules that are easy to break

- **Everything is in English:** code, comments, docs, commit messages.
- **No local paths** in anything committed: no home directories, no sibling checkouts. Link to other
  repositories by their GitHub URL.
- **Pins live in `packages/ehosctl/lib/ehosctl/template.ex`, and nowhere else.** That covers the
  toolchain, the archives and the installer version. The template reads the toolchain from the
  runtime it runs under, so it never pins a second copy. The one copy, the root `.tool-versions`
  the template is developed under, is kept equal to them by `Ehosctl.TemplateTest`.
- **The installer is idempotent.** A second `mix ehos_app.install` changes nothing, and a test pins
  that. Every new change it makes must keep the test green.
- **Compose, don't copy.** When a dependency ships an Igniter installer (as Oban does), compose it
  instead of writing its config yourself. More generally, prefer a standard, community-proven
  library or tool to writing one, and say why when you don't.
- **Mix is the only entry point:** aliases and Mix tasks. No Makefile, no shell scripts.
- **Check a command's own exit code**, not the pipe's:
  `out=$(mix check 2>&1); rc=$?; echo "$out" | tail; echo $rc`.
- **Run the gate before committing:** `mix check` in each package you touched. Then commit, and
  add a line to that package's `CHANGELOG.md` under `Unreleased`.

## Traps already found

- **Burrito binaries run stale code.** A `prod` binary reuses the payload it unpacked for its
  version. After rebuilding without a version bump, run
  `burrito_out/ehosctl_<target> maintenance uninstall`, or you are testing the old code.
- **Burrito argv reaches Elixir's own CLI** unless the command halts in `Application.start/2` (see
  `Ehosctl.Application`). Keep it synchronous.
- **Burrito's ERTS CDN lags the newest OTP patch.** `packages/ehosctl/.tool-versions` pins a version
  that exists there. Check the URL before raising it.
- **Igniter's install spec has no `sparse:`.** `mix igniter.new --install ehos_app@github:…`
  cannot name `packages/ehos_app`. So `ehosctl init` generates the project without it, then runs
  `Igniter.Util.Install.install/2` there with a Mix dependency that has `sparse:`, which also
  composes Oban's installer. Run as a task directly, `mix ehos_app.install` would skip Oban's.
  Dependencies in subdirectories (like `eh_os_contract`) are added by the installer with
  `Igniter.Project.Deps.add_dep/2`.
- **A generated project reads the private `eh-os-contract` through a BuildKit secret**
  (`docs/spike.md`, Open, point 1).
- **`ehos_app`'s tests fail under a path with a dot directory**, such as a worktree in
  `.claude/worktrees/`: 15 of 18 fail, with no repo found and no patches made. Igniter expands a
  glob to an absolute path (`GlobEx.compile!(Path.expand(glob))`), and GlobEx's `*` skips a
  component starting with a dot unless `match_dot: true`. Run the gate from a checkout whose path
  has none.
- **`Igniter.create_new_file/4` with `on_exists: :skip` overwrites** a file Igniter has not read
  yet: it reads it, puts the new content over it, and writes that. The test project reads back
  `**/*.*`, so it hides this for every file but a dotfile. `write_rendered/3` checks
  `Igniter.exists?/2` first; use it, not `create_new_file/4`, for a file the developer owns.
- **A generated migration has to come after Oban's.** Both installers run in the same second; see
  `migration_timestamp/1`.
- **`mise.toml` is invisible to asdf**, which is why the template writes `.tool-versions`.
- **Release asset names are read by mise.** Its `github:` backend picks a binary by the OS and
  architecture words in `ehosctl_<target>`. A bare `x86` reads as 32-bit and a bare `arm` as armv7,
  which is why the targets are `*_x64` and `*_arm64`.
- **On Windows, `:nouse_stdio` does nothing.** The port runner in `Ehosctl.Init` relies on it to
  give each step the terminal, which is one reason Windows is unsupported
  (`packages/ehosctl/README.md#windows`).

## Trying a change end to end

```sh
cd packages/ehosctl
MIX_ENV=prod BURRITO_TARGET=macos_arm64 mix release --overwrite
burrito_out/ehosctl_macos_arm64 maintenance uninstall
cd "$(mktemp -d)"
EHOSCTL_TEMPLATE_SOURCE=path:<absolute path to packages/ehos_app> <path to the binary> init shop
cd shop && mix ecto.setup && mix precommit
```

CI runs the same path on macOS arm64 and x64 and on Linux x64 and arm64 (the `e2e` job in
`.github/workflows/ci.yml`). A Linux binary can also be tried locally in Docker, since one Mac
builds all four targets.

A change to the installer alone needs no binary: run
`mix igniter.new demo --with phx.new --install ehos_app@path:<absolute path> --example --yes`.
