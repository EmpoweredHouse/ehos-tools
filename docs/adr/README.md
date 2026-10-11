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
| [T-05](0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md) | A generated project follows eh-os-contract's `main` while eh-os-contract tags no release | superseded by T-11 |
| [T-06](0006-ehosctl-reads-its-command-line-with-optimus-and-writes-to-the-terminal-with-owl.md) | `ehosctl` reads its command line with Optimus and writes to the terminal with Owl | accepted |
| [T-07](0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md) | `ehosctl` keeps installations as named contexts, one current, in a JSON file in `~/.config/ehosctl` | accepted |
| [T-08](0008-ehosctl-keeps-a-sign-in-s-refresh-token-in-the-system-s-keychain-else-a-file-only-the-user-reads-and-renews-under-a-lock.md) | `ehosctl` keeps a sign-in's refresh token in the system's keychain, else in a file only the user reads, and renews it under a lock | accepted |
| [T-09](0009-ehosctl-signs-in-with-oidcc-and-answers-the-browser-on-a-loopback-socket-of-its-own.md) | `ehosctl` signs in with oidcc, and answers the browser on a loopback socket of its own | accepted |
| [T-10](0010-ehosctl-call-reaches-an-application-through-eh-os-contract-s-routes-found-through-ehos-s-api.md) | `ehosctl call` reaches an application through `eh_os_contract`'s routes, found through EHOS's API | superseded by T-12 |
| [T-11](0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md) | A generated project pins eh-os-contract's release by the commit its tag names, and moves to a later one with a release of `ehos_app`; supersedes T-05 | accepted |
| [T-12](0012-ehosctl-call-asks-for-a-capability-no-role-grants-so-its-refusal-is-decided-and-recorded.md) | `ehosctl call` asks for a capability no role grants, as each kind in turn, so its refusal is decided and recorded by EHOS or the application; supersedes T-10 | accepted |
