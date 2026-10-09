---
status: accepted
date: 2026-10-09
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-06 · `ehosctl` reads its command line with Optimus and writes to the terminal with Owl

## Context and problem statement

`ehosctl` has one command, `init`, and reads its command line by hand: a `case` over argv in
`Ehosctl.CLI` and a second one in `Ehosctl.Init`, each with its own usage text and its own errors.
Stage 7 of EHOS ([its plan](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/plans/stage-7-ehosctl.md),
step 2, [eh-os#315](https://github.com/EmpoweredHouse/eh-os/issues/315)) adds about thirty commands
over its next steps, several of them with subcommands (`people list | invite | …`,
`env list | show | create | …`): signing in, roles, calling an application, deploying. Written the
way `init` is, each would parse its options, print its help and report its errors in its own way, and
a script could not rely on any of it.

[eh-os D-87](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0087-ehosctl-is-one-tool-for-the-developer-and-the-operator-with-a-governed-plane-through-the-api-and-a-platform-plane-outside-it.md)
also makes `ehosctl` the operator's tool in later stages: a platform plane that makes servers,
installs EHOS and opens tunnels, with the installation code that today lives in eh-os's Mix tasks
moved behind it. Which language and libraries the CLI stands on is decided now, before the commands
that would make it expensive to change.

The second half is output. The governed commands print lists (roles, applications, people), ask
for confirmation, and wait on the network; each needs tables, prompts and progress that look the
same from command to command, and that stay out of the way of `--json`.

## Decision drivers

1. **One way to declare a command**: its arguments, options, help and errors come from one
   declaration, so a new command cannot get them different.
2. **The binary stays one file with its own runtime** ([`docs/research.md`](../research.md), Burrito),
   installed with mise and needing nothing else, and `init` keeps its code and behaviour.
3. **The installation code moves rather than being rewritten** (eh-os D-87, "The installation code
   is not copied"): it is Elixir in eh-os today.
4. **A standard, maintained library over our own code** (`AGENTS.md`, "Compose, don't copy"), with
   few dependencies of its own, since every one ships inside the binary.
5. **Testable without a terminal**: parsing returns data, never halts the VM or prints by itself;
   only `Ehosctl.Application` halts, and only inside the binary (`Ehosctl.CLI`'s contract today).

## Considered options

1. **Optimus for the command line, Owl for output**
2. **`OptionParser` alone**, from Elixir's standard library, with our own command tree and help
3. **do_it**, a framework of command modules over `OptionParser`
4. **`ehosctl` rewritten in Go**, with cobra for the command line

## Decision outcome

Chosen option: **"Optimus for the command line, Owl for output"**, because it gives every command
one declaration from which parsing, help and errors follow (driver 1) while keeping the binary, the
`init` code and the Elixir that D-87 moves (drivers 2 and 3), with two well-used libraries and no
runtime dependencies between them (driver 4).

- **[Optimus](https://hex.pm/packages/optimus)** (0.6.1, MIT, no runtime dependencies) declares
  the command tree: nested subcommands, positional arguments, flags and options with parsers and
  defaults, and generated help and usage. `ehosctl` calls `Optimus.parse/2`, which returns data
  (`{:ok, path, result}`, `{:error, path, errors}`, `:help`, `{:help, path}`, `:version`), and
  never `Optimus.parse!/3`, which prints and halts. Help is rendered with `Optimus.Help.help/3` at a
  width `ehosctl` passes in, since Optimus's own default runs `tput cols`.
- **[Owl](https://hex.pm/packages/owl)** (0.13.1, Apache-2.0; its one dependency, `ucwidth`, is
  optional and left out) prints for a person: styled text (`Owl.Data.tag/2`), tables
  (`Owl.Table`), prompts (`Owl.IO.confirm/1`, `select/2`, `input/1`), spinners and progress bars.
  It is used only on the path that writes words for a person; `--json` and errors on stderr are
  plain `IO`, so a script never sees a colour code or a redrawn line.
- **What Optimus does not do, `ehosctl` does in one place.** Optimus treats `--help` as special
  only at the top (`ehosctl --help`), not after a subcommand, so `Ehosctl.CLI` turns
  `ehosctl <command…> --help` into `help <command…>` before parsing. It has no notion of a plane,
  an exit code per kind of error, or `--json`; those are `ehosctl`'s conventions, kept beside the
  command tree in `Ehosctl.CLI`.

### Consequences

- Good, because a command is a declaration in the tree plus a function that returns a result:
  help, usage, unknown-option and missing-argument errors come from Optimus and look the same for
  every command.
- Good, because the CLI stays Elixir: Burrito's binary for four platforms, the release process, the
  `init` code, and the installation code that a later stage moves from eh-os, without a port.
- Good, because Optimus returns data, so the tests call `Ehosctl.CLI.main/2` and assert on its exit
  code and output, as they do today.
- Bad, because Optimus is maintained by one person and released rarely (0.5.0 in July 2023, 0.6.0
  and 0.6.1 in early 2026). Mitigation: it is under two thousand lines with no dependencies, so if
  it stopped being maintained, a fork, or a move to `OptionParser` behind the same declarations,
  is a contained change in `Ehosctl.CLI`.
- Bad, because Optimus's help layout is its own (`USAGE:`, `ARGS:`, `FLAGS:`, `OPTIONS:`, `SUBCOMMANDS:`), which differs
  from the hand-written help `ehosctl --help` prints today. Accepted: the help changes once, now,
  and then stays the same for every command. What it says about the template's pins is kept,
  printed after Optimus's part.
- Bad, because Owl starts its own supervision tree (a live screen, a registry, task supervisors)
  when the binary boots, which `ehosctl` mostly does not use. Accepted: it is a few processes, and
  it is started before `Ehosctl.Application` runs the command, as any dependency's application is.
- Bad, because a tunnel or a keychain, which D-87's later stages need, is harder in Elixir than in
  Go: Erlang has `:ssh` but no client-go for port-forwarding, and no keychain library; `ehosctl`
  would call `kubectl`, `ssh`, `security` or `secret-tool`. Mitigation: D-87 already makes the
  platform plane call external tools, checked by `doctor`, as `init` calls `mise`. Revisit if a
  command needs what only a native library gives.
- Neutral: Burrito unpacks its payload on first run of a version, so the first command after an
  upgrade is slower than a Go binary's; every later one starts from the unpacked runtime.

### Confirmation

- `Ehosctl.CLITest` asserts that `ehosctl --help` and `ehosctl init --help` are rendered by
  Optimus from the declared tree, and that an unknown command and an unknown option exit with the
  documented code for an invalid command line.
- `Ehosctl.InitTest` passes unchanged: `init` behaves as before on the new parser.
- A test lists every command in the tree with its plane (eh-os D-87's confirmation), which only
  works because the tree is one declaration.

## Pros and cons of the options

### Optimus and Owl

- Good, because both are the most used Elixir libraries for their job on hex.pm (Optimus about
  590,000 downloads, Owl about three million), MIT and Apache-2.0, and add nothing else to the
  binary.
- Good, because Optimus's parser returns data and its help is a function of the declaration.
- Bad, because Optimus is a one-person project with long gaps between releases.

### `OptionParser` alone

- Good, because it is Elixir's own and adds no dependency.
- Bad, because it parses one command's switches and nothing else: the command tree, help, usage,
  required arguments and error messages would be ours to write and keep consistent for thirty
  commands, which is the code this decision exists to avoid.

### do_it

- Good, because each command is a module with its own arguments and options, close to how
  `ehosctl` already splits commands into modules.
- Bad, because it is little used (about 2,400 downloads in all, against Optimus's 590,000), with
  one release in the past year, and it is a framework that owns the entry point rather than a
  library `Ehosctl.CLI` calls.

### Go with cobra

- Good, because cobra is the standard for this kind of tool (`kubectl`, `gh`, `helm`), and Go has
  native libraries for what D-87's later stages need: client-go for port-forwarding and tunnels,
  `go-keyring` for the system's keychain, an SSH client.
- Good, because a Go binary is small and starts at once, with no payload to unpack.
- Bad, because it rewrites `ehosctl`: `init`, its tests, the Burrito build and the release, all
  working and shipped (0.2.0).
- Bad, because the installation code D-87 moves into `ehosctl` is Elixir in eh-os, and D-87 keeps
  one copy, possibly as a library shared with `mix ehos.cluster`. In Go it would be ported instead,
  giving two implementations of installing EHOS, which is what D-87's driver 4 rules out.
- Bad, because ehos-tools and eh-os would need a second language and toolchain, for a team that
  writes Elixir.

## More information

- Decided under Stage 7's plan, step 2, and accepted by Emil on 9 October 2026, on [eh-os#315](https://github.com/EmpoweredHouse/eh-os/issues/315)
  and [ehos-tools#72](https://github.com/EmpoweredHouse/ehos-tools/issues/72).
- Optimus: <https://github.com/savonarola/optimus>. Owl: <https://github.com/fuelen/owl>. do_it:
  <https://github.com/rzcastilho/do_it>. cobra: <https://github.com/spf13/cobra>.
- Revisit if Optimus stops being maintained while a fix is needed, or when a stage of D-87 needs a
  capability (a tunnel, a keychain) that calling an external tool cannot give.
