# Decision records

Why ehos-tools is the way it is, one decision per file, numbered `T-01`, `T-02`, … in the
[MADR](https://adr.github.io/madr/) format. Decisions about EHOS itself are EHOS's, numbered
`D-xx`, in [eh-os's `docs/adr/`](https://github.com/EmpoweredHouse/eh-os/tree/main/docs/adr), and
the choices made before these records began are in [`docs/research.md`](../research.md).

A record is written with the `write-adr` skill (`.claude/skills/write-adr/`). An accepted record
is never rewritten: a later one supersedes it.

| ID | Decision | Status |
| --- | --- | --- |
| [T-01](0001-ehos-tools-keeps-its-own-decision-records.md) | ehos-tools keeps its own decision records, numbered T-xx, beside EHOS's D-xx | accepted |
| [T-02](0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md) | A project takes a later ehos_app by running its installer again, not through `mix igniter.upgrade` | accepted |
| [T-03](0003-ci-checks-that-a-pull-request-records-its-authors-review.md) | CI checks that a pull request's description records its author's review | accepted |
| [T-04](0004-ci-runs-only-what-a-change-or-a-release-needs.md) | CI tries the binaries end to end only for a release, and checks and builds only what a change touches | accepted |
| [T-05](0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md) | A generated project follows eh-os-contract's `main` while eh-os-contract tags no release | accepted |
| [T-06](0006-ehosctl-reads-its-command-line-with-optimus-and-writes-to-the-terminal-with-owl.md) | `ehosctl` reads its command line with Optimus and writes to the terminal with Owl | accepted |
