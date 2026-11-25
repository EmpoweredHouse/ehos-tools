# Security policy

This page tells you how to report a security problem in ehos-tools. It covers each package of
this repository, and the applications that the template `ehos_app` generates.

## Report a vulnerability

Do not open a public issue for a security problem. A public issue shows the problem to everyone
before a fix exists.

1. Open the [private vulnerability report form](https://github.com/EmpoweredHouse/ehos-tools/security/advisories/new)
   of this repository.
2. Describe the problem, the version that you used, and the steps that show the problem.
3. Remove tokens, keys and passwords from logs before you attach them.

Only you and the maintainers of the repository see the report. The maintainers reply in the
report, agree on a fix with you, and publish a security advisory when the fix is released.

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

An application that the template generated gets a fix when its developer moves its `ehos_app`
dependency to the fixed version and runs `mix ehos_app.install` again.

## Out of scope

- A problem in EHOS itself, the platform that `ehosctl` talks to. Report it to the
  [eh-os](https://github.com/EmpoweredHouse/eh-os) repository.
- A problem in the contract engine `ehos_contract`. Report it to the
  [ehos_contract](https://github.com/EmpoweredHouse/ehos_contract) repository.
- A problem in a dependency, such as Phoenix, Igniter or Burrito. Report it to that project.
