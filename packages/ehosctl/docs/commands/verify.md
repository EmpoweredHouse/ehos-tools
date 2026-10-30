# Checking an application

```sh
cd shop
ehosctl verify
ehosctl verify --no-test
```

`verify` checks the application in the current directory as its CI does. It runs the gates the
template's CI runs, in that order, and stops at the first that fails:

1. `mix deps.get --only test --check-locked`, which fails when `mix.lock` is behind `mix.exs`, and
   fetches what is missing, as CI does: it needs the network and access to the application's git
   dependencies
2. `mix hex.audit`, which fails on a package in `mix.lock` that is retired or has a security
   advisory, where `mix deps.get` only prints it. It refuses Hex before 2.5.1, which checks
   retirements alone and passes a lock with advisories, as `mix precommit` does; 2.5.1 is also
   the first to acknowledge one under `hex: [ignore_advisories: [...]]` in `mix.exs`. It needs
   the network: `HEX_OFFLINE=1` audits against Hex's cache
3. `mix format --check-formatted`
4. `mix compile --warnings-as-errors`
5. `mix credo`, when Credo is among `mix.lock`'s packages, with no flags of `verify`'s own: the
   application's `.credo.exs` decides what it checks. Without Credo, `verify` says the lint was
   left out, and still passes. Give Credo `only: [:dev, :test]`, since the gates fetch the test
   environment's dependencies alone: `mix help credo` runs first, and fails when Credo is in the
   lock but not a task there, kept for `:dev` alone or removed from `mix.exs` and not unlocked
6. `mix test`, left out with `--no-test` for a check without a database
7. `mix eh_os_contract.check`
8. `mix eh_os_contract.schema --check`, when the application keeps an `eh_os_contract.lock`:
   every event still reads the rows the lock records
9. `mix eh_os_contract.bundle`, into `_build/ehos.bundle/`, out of the source tree, when the
   application's `eh_os_contract` has it: the manifest and the graph documents with their
   `bundle.json`, which `builds register` and `deploy --bundle` read ([Builds](builds.md)). The
   directory is emptied first, and the bundle read back as those commands read it. With an
   `eh_os_contract` before it, `mix eh_os_contract.manifest`, into `_build/ehos.manifest.json`

They run under the application's own `.tool-versions`, through `mise exec`, with `MIX_ENV=test`,
as in CI, and print to the terminal as they would there. They run the project's own code, as
`mix test` by hand does: run `verify` only in a checkout you trust.

Then, when an installation is chosen (`--installation`, `EHOSCTL_INSTALLATION`, or the current
one), EHOS checks the `ehos.yaml` and the manifest
([eh-os `docs/ehos-yaml.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ehos-yaml.md),
"Checking a file"), and `verify` prints what it refuses, with each error's path and line. With none
chosen, it says EHOS's check was left out, and still passes; CI has no sign-in. It submits nothing.

- A gate that fails, a manifest that was not written or is larger than EHOS takes, or a document
  EHOS refuses exits 1.
- A directory without `mix.exs`, `ehos.yaml` or `.tool-versions`, each a regular file, exits 2.
- An installation named and unknown, or a sign-in that has expired, exits 4, before anything runs
  for the first and after the gates for the second.
