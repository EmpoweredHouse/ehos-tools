# What is in use, and what is newer

```sh
ehosctl versions
ehosctl versions --json
ehosctl changelog ehosctl
ehosctl changelog eh_os_contract --since 0.2.1
ehosctl changelog ehos_app --web
```

`versions` prints a row for each of EHOS's components: `ehosctl` itself, the installation's EHOS
(`ehos`), and in an application's directory, one with a `mix.exs`, a `mix.lock`, and an
`ehos.yaml` or `ehos_app` among its dependencies, its `ehos_app`, `eh_os_contract` and
`ehos_design`, with a row for its `ehos.yaml` (`no ehos.yaml` when it has none) and, once `verify`
has written one, its manifest. Any other Mix project, such as an eh-os checkout, which depends on
`ehos_design`, is shown as outside any project. Each row says:

- **in use**: `ehosctl`'s own version, and its commit for a build between releases; what the
  installation says it runs at `GET /api/v1`; what `mix.lock` locks. A locked commit is matched
  to the release whose `release.json` names it, else to the component's tag that names it, as
  for `ehos_app`'s releases before 0.7.0, which are tags alone and are judged `unknown`; one that
  is neither is said as a commit, with how far it is from the newest release (`main at 743e91d,
  738 commits behind 0.3.0`);
- **accepted**: whether the installation accepts it, as eh-os
  [D-91](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0091-every-component-releases-the-same-way-and-says-which-interfaces-it-produces-and-accepts.md)
  says, from what the installation says it produces, accepts and requires, against the
  component's own `release.json`: `ehosctl` meets the installation's `requires.ehosctl` and reads
  the API it serves; the `ehos.yaml` an `ehos_app` writes is one the installation accepts; so is
  the manifest the application writes with `eh_os_contract`; `ehos_design` has no interface with
  EHOS. A release is judged the other way too, where its `release.json` says: what the
  installation produces must be what it reads, and what it requires of `ehos` must hold. A
  `release.json` is used only when it is its release's (schema, component and version). `yes`,
  `no` or `unknown`, and below the table why;
- **the newest release**, from GitHub, and whether the installation would accept it;
- **the command that moves to it**, when it is newer and not refused: for `ehosctl`,
  `mise use -g github:EmpoweredHouse/ehos-tools@<version>`;
  for `ehos_app`, pointing its `ref:` at the commit the release names and running
  `mix ehos_app.install` again; for `eh_os_contract` on eh-os-contract's `main`, as `ehos_app`
  0.5.0 to 0.6.1 wrote it, moving `ehos_app` to the newest release whose `release.json` admits
  it, that the installation does not refuse and that is newer than the one in use, or once one
  does, and running its installer again (only that, when the one in use admits it), which moves
  both of eh-os-contract's packages
  ([T-11](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md));
  for one the installer keeps, a fork, another branch, a tag or a commit of the project's own,
  moving both `ref:`s and requirements by hand; for `ehos_design`, moving its `ref:`; for EHOS,
  which is the operator's, `ehosctl upgrade --to <version>`.

The installation, GitHub and `mix.lock` can each fail alone. With no installation chosen, only
the releases are judged; without GitHub (offline, no token, refused), only the installation and
the application. What a source could not say is said, with why, and `versions` exits 0 whatever
its sources answered: only an installation named and unknown exits 4. GitHub is read up to its
newest 1000 releases in each repository; a repository with more is said to be listed in part, and
`--json` names it under `listed_in_part`, apart from what was not read at all, under `unread`.
A repository's tags are read only for a locked commit no `release.json` names, once for all its
components, up to 1000 and no further than the page that names every such commit; tags not read
are under `unread.github_tags`, and those read in part under `tags_listed_in_part`.

`changelog <component>` prints the notes of each release of `ehosctl`, `ehos`, `ehos_app`,
`ehos_design` or `eh_os_contract` newer than the version in use, newest first, each under its
version: a release's section of its changelog, from the `notes.md` it attaches when there is one,
else its description. It prints the 50 newest at most, and says how many older ones it left out.
The version in use is `ehosctl`'s own, the one the installation runs for `ehos`, and the one
`mix.lock` locks for the others; when it cannot be found, `changelog` says why and asks for
`--since <version>` (exit 2). `--web` opens the newest release's page in the browser and prints
its address; `--json` gives the releases as data, and how many it left out as `left_out`.

The releases are read from GitHub's API with the token mise already uses,
`MISE_GITHUB_TOKEN`, else `GITHUB_TOKEN`: the repositories are private, and without one GitHub
does not show them, which is what `ehosctl` then says. `export GITHUB_TOKEN=$(gh auth token)` is
enough. The token is sent to `api.github.com` alone and never kept; downloading a release's file,
which GitHub redirects to another host, carries none.

## The update notice

After a command, at most once a day, `ehosctl` says on stderr that a newer `ehosctl` is released,
with `mise use -g github:EmpoweredHouse/ehos-tools@<version>`, the command that installs it
([Upgrading](https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehosctl/README.md#upgrading)
says why it names the version), or that the installation the command used no longer accepts this one, and that `ehosctl versions` says whether
it accepts the newest release. It is never printed in CI (`CI` set to anything), under `--json`, when stderr is not a
terminal, after `versions` and `changelog`, or when `EHOSCTL_NO_UPDATE_NOTICE` is set. It comes
after the command's own output and never changes it or its exit code. What it learned is kept in
`notice.json` in the [cache directory](init.md#where-it-writes), and asked again once a day, within two seconds, of
GitHub and of the installation; the installation is asked only with the credential the command
left, never by renewing a sign-in. When that file cannot be written, nothing is asked or said.
