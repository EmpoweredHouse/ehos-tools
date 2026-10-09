---
status: accepted
date: 2026-10-09
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-07 · `ehosctl` keeps installations as named contexts, one current, in a JSON file in `~/.config/ehosctl`

## Context and problem statement

Every governed command of `ehosctl` (eh-os D-87) talks to one installation of EHOS. A developer
works with more than one: the local cluster, a staging installation, a client's. Stage 7's
plan ([step 2](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/plans/stage-7-ehosctl.md),
[eh-os#315](https://github.com/EmpoweredHouse/eh-os/issues/315)) asks for installations as named
contexts, one of them current, as kubectl has them, and `--installation` on every governed command.
So `ehosctl` needs a configuration that outlives a command: which installations a person knows,
under which names, and which one a command talks to when none is named.

What it holds is read by every governed command, written by `login` (step 4) and by switching
installations, and read by people who wonder what `ehosctl` knows about them. Its location and
shape are a contract: once people have files, a change to either needs a migration. That is why it
is decided now, before `login` writes the first one.

The sign-in's token is not part of this record. Where it is kept, a file readable only by the user
or the system's keychain, is step 4's own record.

## Decision drivers

1. **A person can find it, read it and edit it**, and back it up or keep it with their dotfiles.
2. **One way to say which installation**, the same for every governed command, which a script can
   set without changing the person's current one.
3. **No secret in it**, so it can be read, shown and shared without care; the token lives apart.
4. **No dependency for a file this small** (`AGENTS.md`, "Compose, don't copy", weighed against
   everything a dependency puts inside the binary), and a file that is never left half written.
5. **Room to change it**: a later version can tell an old file from a new one.

## Considered options

1. **JSON, in `$XDG_CONFIG_HOME/ehosctl/config.json`** (`~/.config/ehosctl` by default, on macOS
   too), as gh and mise place theirs
2. **The same, in the operating system's own directory**: `:filename.basedir(:user_config, …)`,
   which is `~/Library/Application Support/ehosctl` on macOS
3. **A dotfile in the home directory**, `~/.ehosctl/config`, as kubectl keeps `~/.kube/config`
4. **TOML**, as mise writes its own, in either location
5. **YAML with kubectl's shape**: separate lists of clusters, users and contexts that join them

## Decision outcome

Chosen option: **"JSON, in `$XDG_CONFIG_HOME/ehosctl/config.json`"**, because it is where people
who use gh and mise already look (driver 1), Elixir reads and writes it with its own `JSON` module
(driver 4), and an installation is simple enough that a flat map says it plainly.

- **Where.** `$EHOSCTL_CONFIG_DIR` if set, else `$XDG_CONFIG_HOME/ehosctl`, else
  `~/.config/ehosctl`; the file is `config.json` in it. The variable lets a test, a CI job or a
  second identity use a directory of its own, as `KUBECONFIG` and `GH_CONFIG_DIR` do.
- **Shape.**

  ```json
  {
    "version": 1,
    "current": "staging",
    "installations": {
      "local": {"url": "http://ehos.localhost"},
      "staging": {"url": "https://ehos.staging.example.com"}
    }
  }
  ```

  An installation is a name and the address of its EHOS. Who is signed in to it, and until when,
  is what step 4 adds beside the URL, never the token itself. kubectl's split into clusters, users
  and contexts is left out: one person signs in to an installation once, and a second identity on
  the same installation is a second name with the same URL.
- **Names** are what a person types after `--installation`: lowercase letters, digits and dashes,
  starting with a letter, as a DNS label. `login` (step 4) proposes one from the URL's host.
- **Which installation a governed command talks to**: `--installation NAME`, else
  `EHOSCTL_INSTALLATION`, else `current`. With none of them, or a name that is not in the file, the
  command fails as *not signed in* (`Ehosctl.Output`), saying how to sign in.
- **Writing.** `ehosctl` writes the whole file to a temporary file in the same directory and
  renames it over the old one, so a command interrupted half way leaves the old file, not half of a
  new one. The directory is created readable only by the user (`0700`) and the file `0600`: it holds
  no secret, but it says which installations a person uses.
- **Reading.** A file whose `version` is newer than this `ehosctl` knows is refused with a message to
  upgrade `ehosctl`, rather than read in part and written back without what it did not understand.
- **Commands.** `ehosctl installations list` lists the installations and marks the current one
  (`--json` for scripts), `ehosctl installations use NAME` makes one current, and
  `ehosctl installations remove NAME` forgets one. All three are on the local plane: they read and
  write this file and nothing else. Adding one is `login`'s (step 4).

### Consequences

- Good, because a person finds the file where gh's and mise's are, can read it in any editor, and
  `jq` reads it in a script.
- Good, because a script can name its installation with `EHOSCTL_INSTALLATION` without changing
  what the person's next command talks to, as `KUBECONFIG` can be set for one command.
- Good, because the file holds no secret, so showing it in an issue or a screen share leaks nothing
  but names and addresses.
- Bad, because JSON has no comments, so a person cannot annotate an entry, and a trailing comma
  made by hand breaks it. Mitigation: `ehosctl` says where the file is and what is wrong with it
  when it cannot read it, and the commands above mean nobody has to edit it by hand.
- Bad, because macOS's own convention is `~/Library/Application Support`, and a strict reading of it
  would put the file there. Accepted: command-line tools for developers (gh, mise, and many more)
  use `~/.config` on macOS, which is where their users look.
- Bad, because the file is read and rewritten by whichever command runs, so two commands that write
  at the same moment, such as two `login`s, can lose one write. Accepted: the rename keeps the file
  whole; the lost write is a `use` or a `login` that the person repeats.
- Neutral: Windows is not supported ([`packages/ehosctl/README.md`](../../packages/ehosctl/README.md#windows)),
  so its directory is not decided here.

### Confirmation

Tests in `packages/ehosctl`, under a temporary `EHOSCTL_CONFIG_DIR`:

- the directory is chosen from `EHOSCTL_CONFIG_DIR`, then `XDG_CONFIG_HOME`, then `~/.config`;
- `--installation`, then `EHOSCTL_INSTALLATION`, then `current` decide the installation, and none
  of them is *not signed in*, with its exit code;
- the file written is the shape above, `0600` in a `0700` directory, and a file of a newer
  `version` is refused unchanged;
- `installations list`, `installations use` and `installations remove` are listed with the local plane
  in `Ehosctl.CommandTest`.

## Pros and cons of the options

### JSON in `~/.config/ehosctl`

- Good, because Elixir reads and writes it without a dependency, and the location is the one
  developers' tools share.
- Bad, because JSON is less pleasant to edit by hand than TOML or YAML.

### The operating system's directory

- Good, because it is Erlang's own answer (`:filename.basedir/2`) and follows each platform's
  convention.
- Bad, because on macOS that is `~/Library/Application Support/ehosctl`, a path with a space that
  people do not look in for a command-line tool's configuration and that dotfile managers skip.

### A dotfile in the home directory

- Good, because kubectl's users know `~/.kube`.
- Bad, because it adds one more directory to the home directory, where XDG's directory exists for
  this, and it ignores `XDG_CONFIG_HOME` for people who set it.

### TOML

- Good, because it is pleasant to edit, has comments, and mise's users read it every day.
- Bad, because it needs a dependency that also writes: `toml`, the most used, only decodes, and the
  one that encodes, `toml_elixir`, is young (about 41,000 downloads). And what the file holds is
  written by `ehosctl` far more often than by a person.

### YAML with kubectl's shape

- Good, because kubectl's users would recognise both the format and the split.
- Bad, because it needs two dependencies, `yaml_elixir` to read and `ymlr` to write, and the
  split into clusters, users and contexts serves a case `ehosctl` does not have: one cluster
  reached by many users through many contexts.

## More information

- Decided under Stage 7's plan, step 2, and accepted by Emil on 9 October 2026, with the commands'
  names, on [eh-os#315](https://github.com/EmpoweredHouse/eh-os/issues/315)
  and [ehos-tools#72](https://github.com/EmpoweredHouse/ehos-tools/issues/72).
- gh's location: `GH_CONFIG_DIR`, else `$XDG_CONFIG_HOME/gh`, else `~/.config/gh`. kubectl's:
  `KUBECONFIG`, else `~/.kube/config`.
- Revisit when the token's storage (step 4) needs something in this file other than who is signed
  in and until when, or if `ehosctl` is supported on Windows.
