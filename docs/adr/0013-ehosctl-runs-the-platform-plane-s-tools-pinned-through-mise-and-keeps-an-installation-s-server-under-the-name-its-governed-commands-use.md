---
status: proposed
date: 2026-10-12
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-13 · `ehosctl` runs the platform plane's tools pinned through mise, and keeps an installation's server under the name its governed commands use

Decides what [eh-os D-92](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0092-the-installation-code-is-a-package-in-ehos-tools-and-ehos-s-release-carries-the-chart-and-modules-it-installs.md)
left to ehos-tools: how platform commands run their tools, and how an installation's
`~/.ehos/<name>/` relates to the installations
[T-07](0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md)
keeps. Decided under eh-os Stage 13, step 3 (EmpoweredHouse/eh-os#406; #146 here).

## Context and problem statement

`ehosctl`'s platform plane (eh-os D-87) makes a server and installs EHOS with `ehos_platform`
(eh-os D-92), which runs `tofu`, `helm`, `kubectl` and `ssh` through `EhosPlatform.CommandRunner`.
eh-os runs that code with the tools its `.tool-versions` pins, from a developer's mise or asdf.
An operator running `ehosctl` has no checkout and no `.tool-versions`, and whatever `tofu` or
`helm` is on their `PATH`. Two of these tools are not forgiving about versions. OpenTofu writes
its state in its own version's format and refuses to read a newer one. Helm 4 refuses some of what
Helm 3 accepted.

The server's own state is `~/.ehos/<name>/`: its OpenTofu state, its kubeconfig and its tunnel.
`mix ehos.server` made the ones that exist today (Stage 10). `ehosctl` also keeps installations
under names (T-07): `config.json`, with each one's URL and sign-in, and a current one. A platform
command and a governed one about the same installation need to agree on which one is meant.

## Decision drivers

1. **The versions eh-os tests are the versions an operator runs.** The Cluster job installs with
   eh-os's pins. An operator's tools should match them, or the operator is the first to try a
   combination.
2. **An installation made with Mix is taken over as it is** (eh-os Stage 13, Risks). Stage 10's
   server keeps working with no migration.
3. **One name per installation.** `ehosctl server up --installation acme` followed by
   `ehosctl people list --installation acme` must mean the same EHOS.
4. **`ehosctl doctor` installs nothing** (eh-os D-92). It says what is missing and how to get it.
5. **`init` and `verify` already need mise** to run Erlang and Elixir at `ehosctl`'s pins.

## Considered options

How the tools run:

- **A.** `mise exec <tool>@<pin> -- <program>`, with the pins in `ehos_platform`
- **B.** Whatever `tofu`, `helm` and `kubectl` are on the `PATH`
- **C.** `ehosctl` downloads and checks each tool itself
- **D.** The tools are embedded in `ehosctl`'s binary

Where an installation's server lives, and under which name:

- **1.** `~/.ehos/<name>/` as today, chosen by the same rule as a governed command's installation
- **2.** A name space of its own, `--name`, apart from `--installation`
- **3.** The server's state moved into `ehosctl`'s config directory, beside `config.json`

## Decision outcome

Proposed: **A** and **1**.

- **The tools are pinned and run through mise.**
  - `ehos_platform` declares what it runs and at which versions (`EhosPlatform.Tools`): OpenTofu,
    Helm and kubectl, at the versions eh-os's `.tool-versions` pins. A test in eh-os holds the two
    equal once eh-os pins a release of the package that has them.
  - `ehosctl`'s runner for the package, `Ehosctl.PlatformRunner`, runs `tofu`, `helm` and
    `kubectl` as `mise exec <tool>@<version> -- <program> <args>`. It sets
    `MISE_EXEC_AUTO_INSTALL=false`, so a missing tool fails at once and names the command that
    installs it, instead of a download in the middle of `server up`.
  - `ssh` and `ssh-keygen` are the system's, as eh-os D-92 says. `ehosctl` finds them on the
    `PATH`.
- **An installation's server stays in `~/.ehos/<name>/`, named as governed commands name it.**
  - A platform command takes `--installation <name>`, and else `EHOSCTL_INSTALLATION`, and else the
    current installation: T-07's rule. With none of them it is `trial`, `mix ehos.server`'s
    default, so a server made with Mix is found under its name.
  - `~/.ehos/<name>/` is the platform plane's, and `config.json` is the governed plane's. Neither
    reads the other's files. `ehosctl install` (eh-os Stage 13, step 5) adds or updates the
    installation of the same name in `config.json` with the console's URL. `ehosctl login` then
    finds it.
  - The names are T-07's: lowercase letters, digits and `-`, which `mix ehos.server` already
    requires of a directory.
- **`ehosctl doctor`** looks each tool up with `mise where <tool>@<version>`, which installs
  nothing, and prints `mise install <tool>@<version>` for each one missing.

### Consequences

- **Good:**
  - An operator's `server up` runs the OpenTofu that eh-os's checks ran. A state written by one
    version is read by the same version on every run, from every machine with mise.
  - A Stage 10 server made with Mix is `ehosctl server status` away: same directory, same name,
    same files.
  - One name, one installation, across both planes.
- **Bad:**
  - mise becomes a requirement of every platform command, not only of `init` and `verify`.
    `doctor` says so first.
  - A tool's version moves in two places: eh-os's `.tool-versions` and `ehos_platform`. The test
    in eh-os catches a difference once the pin moves.
  - `--installation` defaulting to the current installation means a platform command can act on
    one the person did not type. `server down` therefore names the installation and asks before
    it removes anything, as `mix ehos.server down` does.
- **Neutral:** `mix ehos.server` keeps running the tools from the `PATH` until eh-os Stage 13,
  step 7, removes it.

### Confirmation

- A test of `Ehosctl.PlatformRunner` shows `helm`, `tofu` and `kubectl` run as `mise exec
  <tool>@<pin> -- …`, with `MISE_EXEC_AUTO_INSTALL=false`, and `ssh` run as itself.
- `Ehosctl.CommandTest` lists `doctor`, `server`, `install` and `upgrade` as `:platform`.
- `ehosctl server status` with no flag reads `~/.ehos/trial/` where no installation is current
  (eh-os Stage 13, step 4).

## Pros and cons of the options

### A. Pinned through mise

- Good, because `init` and `verify` already run their tools this way, and mise checks each
  download against the checksums it pins.
- Bad, because an operator without mise has to install it first.

### B. The tools on the `PATH`

- Good, because nothing more is needed.
- Bad, because a newer OpenTofu writes a state an older one cannot read. An operator's upgrade of
  `tofu` on one machine would lock out every other machine.

### C. `ehosctl` downloads its tools

- Good, because there is nothing to install.
- Bad, because it rewrites what mise does, checksums and platforms included. The repository's
  rule is a standard tool before a new one.

### D. Embedded in the binary

- Good, because it works offline.
- Bad, because the binary would carry three tools for four platforms. Burrito reuses its unpack
  directory for a binary of the same version (#100), so a tool could be stale.

### 1. `~/.ehos/<name>/`, under T-07's name

- Good, because a server made with Mix is found unchanged.
- Bad, because the default can be the current installation rather than one typed.

### 2. A name space of its own

- Good, because the default is always `trial`.
- Bad, because `acme` as a server and `acme` as an installation could then be two things.

### 3. In `ehosctl`'s config directory

- Good, because everything `ehosctl` keeps would be in one place.
- Bad, because every server made with Mix would have to move. T-07's directory holds no secret by
  design, and the OpenTofu state and the kubeconfig are secrets.

## More information

- **Follows:** eh-os D-87 (two planes), eh-os D-92 ("What will be ehosctl's own decision"), T-07.
- **Revisit:** when an installation's state is shared between operators (eh-os#251), which takes
  the OpenTofu state off one machine, or when mise can no longer install one of the tools.
