# Security policy

This page tells you how to report a security problem in ehos-tools. It covers each package of
this repository, and the code that the template `ehos_app` writes into each application.

## Report a vulnerability

Do not open a public issue for a security problem. A public issue shows the problem to everyone
before a fix exists.

1. Open the [private vulnerability report form](https://github.com/EmpoweredHouse/ehos-tools/security/advisories/new)
   of this repository.
2. Describe the problem, the version that you used, and the steps that show the problem.
3. Remove tokens, keys, passwords and sign-in links from logs before you attach them.

Only you and the maintainers of the repository see the report. The maintainers reply in the
report, agree on a fix with you, and publish a security advisory when the fix is released.

If the form does not open, open a public issue that asks for a private contact. Do not describe
the problem in that issue.

## Supported versions

The maintainers fix security problems in the latest release of each package. Each package has its
own version and its own tags:

| Package | Tags |
| --- | --- |
| `ehosctl` | `vX.Y.Z` |
| `ehos_app` | `ehos_app-vX.Y.Z` |
| `ehos_design` | `ehos_design-vX.Y.Z` |
| `ehos_diagrams` | `ehos_diagrams-vX.Y.Z` |
| `ehos_platform` | `ehos_platform-vX.Y.Z` |
| `ehos_tunnel` | `ehos_tunnel-vX.Y.Z` |
| The Claude Code plugins `ehos-app` and `ehos-dev` | `ehos-app-vX.Y.Z`, `ehos-dev-vX.Y.Z` |

To get a fix of `ehos_app` into an application, its developer moves the `ehos_app` dependency to
the fixed version and runs `mix ehos_app.install` again. The installer does not change a file that
the developer changed. It prints a notice instead, and the developer applies that part of the fix
by hand. The security advisory says which files the fix changes. For the steps, see
[On an existing project, and running it again](packages/ehos_app/README.md#on-an-existing-project-and-running-it-again).

## Out of scope

- A problem in the code of one application, other than the code that the template wrote. Report
  it to the owner of that application.
- A problem in EHOS itself, the platform that `ehosctl` talks to. Report it to the
  [eh-os](https://github.com/EmpoweredHouse/eh-os) repository. While that repository is private,
  report the problem here, and the maintainers send it on.
- A problem in the contract engine `ehos_contract`. Report it to the
  [ehos_contract](https://github.com/EmpoweredHouse/ehos_contract) repository.
- A problem in a dependency, such as Phoenix, Igniter or Burrito. Report it to that project.

## Next steps

- [SUPPORT.md](SUPPORT.md): where to ask a question or report a bug that is not a security problem.
