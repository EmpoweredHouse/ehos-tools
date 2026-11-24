# What is in use, and what is newer

`ehosctl versions` shows the version in use of each EHOS component, the newest release, and if the
installation accepts each. `ehosctl changelog` shows what changed in the newer releases. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl versions
ehosctl versions --json
ehosctl changelog ehosctl
ehosctl changelog ehos_contract --since 0.2.1
ehosctl changelog ehos_app --web
```

## Before you start

`ehosctl` reads the releases from the API of GitHub, with the token that mise already uses:
`MISE_GITHUB_TOKEN`, else `GITHUB_TOKEN`. The repositories are private, so GitHub does not show
them without a token. To give a token, run `export GITHUB_TOKEN=$(gh auth token)`.

`ehosctl` sends the token only to `api.github.com`, and never keeps it. When GitHub redirects a
download of a release file to another host, `ehosctl` does not send the token there.

## See the components in use

`ehosctl versions` prints a row for each component:

- `ehosctl` itself;
- the EHOS of the installation (`ehos`);
- in the directory of an application, `ehos_app`, `ehos_contract` and `ehos_design`, a row for its
  `ehos.yaml`, and a row for its application manifest after `verify` writes one.

A directory of an application has a `mix.exs`, a `mix.lock`, and an `ehos.yaml` or `ehos_app` among
its dependencies. Without an `ehos.yaml`, its row says `no ehos.yaml`. `versions` shows another Mix
project, such as a checkout of eh-os that depends on `ehos_design`, as outside a project.

Each row has these columns:

| Column | What it shows |
| --- | --- |
| IN USE | The version in use. [Where the version in use comes from](#where-the-version-in-use-comes-from) tells more. |
| ACCEPTED | `yes`, `no` or `unknown`: if the installation accepts the version in use. The reason is below the table. |
| NEWEST | The newest release on GitHub. |
| NEWEST ACCEPTED | If the installation would accept the newest release. |

Below the table, `versions` gives the command that moves to the newest release, when the release
is newer and the installation does not refuse it.

### Where the version in use comes from

- For `ehosctl`: its own version, and its commit for a build between releases.
- For `ehos`: what the installation says that it runs, at `GET /api/v1`.
- For the others: what `mix.lock` locks.

`versions` matches a locked commit to the release whose `release.json` names it. Else it matches the
commit to the tag of the component that names it. The releases of `ehos_app` before 0.7.0 are tags
only, and `versions` judges them `unknown`. A commit that is neither shows as a commit, with its
distance from the newest release. For example: `main at 743e91d, 738 commits behind 0.3.0`.

### How `versions` decides if the installation accepts a version

`versions` compares what the installation says that it produces, accepts and requires with the
`release.json` of the component:

- `ehosctl` must meet the `requires.ehosctl` of the installation and read the API that it serves.
- The `ehos.yaml` that an `ehos_app` writes must be one that the installation accepts.
- The application manifest that `ehos_contract` writes must be one that the installation accepts.
- `ehos_design` has no interface with EHOS.

`versions` also checks the other direction, where the `release.json` says it. What the installation
produces must be what the release reads. What the release requires of `ehos` must hold. `versions`
uses a `release.json` only if its schema, component and version are the ones of its release.

### The command that moves to the newest release

| Component | Command |
| --- | --- |
| `ehosctl` | `mise use -g github:EmpoweredHouse/ehos-tools@<version>` |
| `ehos_app` | Set its `ref:` to the commit that the release names, and its requirement to the release. Run `mix deps.get`, then `mix ehos_app.install` again. |
| `ehos_contract` on the `main` of ehos_contract | Move `ehos_app` to a release that admits it, then run `mix ehos_app.install` again. [`ehos_contract` on `main`](#ehos_contract-on-main) tells more. |
| `ehos_contract` on a fork, another branch, a tag or a commit of the project | Move both `ref:`s and the requirements by hand. |
| `ehos_design` | Set its `ref:` to the commit that the release names, then run `mix deps.get`. |
| `ehos` | `ehosctl upgrade --to <version>`. The operator of the installation runs it. |

### `ehos_contract` on `main`

`ehos_app` 0.5.0 to 0.6.1 wrote `ehos_contract` on the `main` of ehos_contract. Such a project
moves with `ehos_app`, because the installer of `ehos_app` moves both packages of ehos_contract.
`versions` names the newest release of `ehos_app` that matches all of these:

- its `release.json` admits the release of `ehos_contract`;
- the installation does not refuse it;
- it is newer than the `ehos_app` in use.

If the `ehos_app` in use already admits the release, run its installer again. If no release of
`ehos_app` admits it yet, `versions` says to move when one does.

## What occurs when a source does not answer

The installation, GitHub and `mix.lock` can each fail alone:

- With no installation chosen, `versions` judges only the releases.
- Without GitHub (offline, no token, or refused), it judges only the installation and the
  application.

`versions` says what a source could not say, and why. It exits with 0 whatever its sources
answered. Only an installation that you named and that is unknown makes it exit with 4.

`versions` reads up to the 1000 newest releases of each repository on GitHub. For a repository with
more, it says that GitHub listed it in part, and `--json` names it under `listed_in_part`. What it
could not read at all is under `unread`.

`versions` reads the tags of a repository only for a locked commit that no `release.json` names. It
reads them once for all components of the repository, up to 1000, and stops at the page that names
each such commit. `--json` puts tags that it could not read under `unread.github_tags`, and tags
that it read in part under `tags_listed_in_part`.

## See what changed in newer releases

`ehosctl changelog <component>` prints the notes of each release that is newer than the version in
use, newest first, each under its version. The component is `ehosctl`, `ehos`, `ehos_app`,
`ehos_design` or `ehos_contract`. The notes are the section of the changelog of the release, from
the `notes.md` that the release attaches, else its description. `changelog` prints at most the 50
newest, and says how many older ones it left out.

The version in use is the version of `ehosctl` itself, the version that the installation runs for
`ehos`, and the version that `mix.lock` locks for the others. If `changelog` cannot find it, it says
why and asks for `--since <version>`, and exits with 2.

- `--web` opens the page of the newest release in the browser and prints its address.
- `--json` gives the releases as data, and how many it left out as `left_out`.

## The update notice

After a command, at most once a day, `ehosctl` writes a notice on stderr when one of these is true:

- A newer `ehosctl` is released. The notice gives `mise use -g
  github:EmpoweredHouse/ehos-tools@<version>`, the command that installs it.
  [Upgrading](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/README.md#upgrading)
  says why it names the version.
- The installation that the command used no longer accepts this `ehosctl`. The notice says that
  `ehosctl versions` shows if the installation accepts the newest release.

`ehosctl` does not write the notice:

- in CI, when `CI` is set to any value;
- under `--json`;
- when stderr is not a terminal;
- after `versions` and `changelog`;
- when `EHOSCTL_NO_UPDATE_NOTICE` is set.

The notice comes after the output of the command, and never changes that output or its exit code.
`ehosctl` keeps what it learned in `notice.json` in the
[cache directory](init.md#where-it-writes). Once a day, it asks GitHub and the installation again,
within 2 seconds. It asks the installation only with the credential that the command left, and
never renews a sign-in for it. If `ehosctl` cannot write that file, it asks nothing and writes no
notice.

## Next steps

- [Checking an application](verify.md): check an application after you move a component.

## Background

- [eh-os
  D-91](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0091-every-component-releases-the-same-way-and-says-which-interfaces-it-produces-and-accepts.md):
  each component says which interfaces it produces and accepts.
- [ehos-tools
  T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md):
  a generated project pins the release of ehos_contract by the commit that its tag names.
