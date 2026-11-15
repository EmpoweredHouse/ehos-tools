# Checking an application

`ehosctl verify` checks the application in the current directory as its CI does, before you push
or deploy. In the directory of a utility service, it checks `ehos.yaml` and writes the bundle. If
an installation is chosen, EHOS then checks the `ehos.yaml` and the application manifest.
`ehosctl verify` submits nothing. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
cd shop
ehosctl verify
ehosctl verify --no-test
```

## Before you start

- Run `verify` in the directory that holds `mix.exs`, `ehos.yaml` and `.tool-versions` of the
  application, each a regular file. For a utility service, run it in the directory that holds
  `ehos.yaml` and no `mix.exs` ([Check a utility service](#check-a-utility-service)). In another
  directory, `verify` exits with 2.
- `verify` runs the code of the project, as `mix test` does. Run it only in a checkout that you
  trust.
- The first gate needs the network, and access to the git dependencies of the application.

## What `verify` runs

`verify` runs the gates that the CI of the application template runs, in the same order. It stops
at the first gate that fails, and exits with 1.

1. `mix deps.get --only test --check-locked`. It fails if `mix.lock` is behind `mix.exs`, and
   fetches what is missing, as CI does.
2. `mix hex.audit`. It fails if a package in `mix.lock` is retired or has a security advisory.
   `mix deps.get` only prints these. `verify` refuses a Hex before 2.6.0, as `mix precommit` of
   `ehos_app` after 0.24.0 does. Before 2.6, an audit passed when it could not fetch the registry,
   and did not check the packages. Before 2.5, an audit checked only retirements. To acknowledge an
   advisory, add it under `hex: [ignore_advisories: [...]]` in `mix.exs`. The audit needs the
   network. `HEX_OFFLINE=1` audits against the cache of Hex.
3. `mix format --check-formatted`.
4. `mix compile --warnings-as-errors`.
5. `mix credo`, if Credo is among the packages in `mix.lock`. `verify` gives it no flags of its own:
   the `.credo.exs` of the application decides what it checks. Without Credo, `verify` says that it
   skipped the lint, and still passes. Give Credo `only: [:dev, :test]`, because the gates fetch
   only the dependencies of the test environment. `mix help credo` runs first. It fails if Credo is
   in the lock but is not a task there. For example, Credo is only for `:dev`, or `mix.exs` no
   longer has it and the lock still does.
6. `mix test`. `--no-test` skips it, for a check without a database.
7. `mix eh_os_contract.check`.
8. `mix eh_os_contract.schema --check`, if the application keeps an `eh_os_contract.lock`. It
   checks that each event still reads the rows that the lock records.
9. `mix eh_os_contract.bundle`, into `_build/ehos.bundle/`, outside the source tree, if the
   `eh_os_contract` of the application has it. The bundle holds the application manifest and the
   graph documents with their `bundle.json`. `ehosctl builds register` and `ehosctl deploy --bundle`
   read it ([Builds](builds.md)). `verify` empties the directory first, and then reads the bundle
   back as those commands do. With an older `eh_os_contract`, `verify` runs
   `mix eh_os_contract.manifest` into `_build/ehos.manifest.json` instead.

The gates run with the `.tool-versions` of the application, through `mise exec`, with
`MIX_ENV=test`, as in CI. They print to the terminal as they do there.

## What EHOS checks

If an installation is chosen (`--installation`, `EHOSCTL_INSTALLATION`, or the current one), EHOS
checks the `ehos.yaml` and the application manifest
([`docs/ehos-yaml.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ehos-yaml.md) of
eh-os, "Checking a file"). `verify` prints each error that EHOS finds, with its path and line.

If no installation is chosen, `verify` says that EHOS did not check, and still passes. CI has no
sign-in. In a GitHub Actions job, EHOS does not check either, because the credential of the job can
only deploy. There, `ehosctl deploy --preview` checks the application manifest.

## Check a utility service

A utility service is a program with no contract, in any language, that the applications of an
environment share. Its repository holds `ehos.yaml` with `kind: service`, and no Elixir project.

```sh
cd invoice-pdf
ehosctl verify
```

In such a directory, `verify` runs no gate, because the language of the service is the choice of
its author. It does not start the image either. `verify` does these steps:

1. It reads `ehos.yaml` and checks it against `ehos.yaml/v8`, as EHOS reads a file. The check
   works without the network: `ehosctl` holds a copy of the schema of EHOS.
2. It refuses each key that a utility service cannot give, with the reason of EHOS. For example,
   `needs.database` gets "is not for a utility service, which keeps no data of its own: remove
   it". Then `verify` writes no bundle, and exits with 2.
3. It writes the bundle into `_build/ehos.bundle/`: `bundle.json` and `ehos.manifest.json`, with no
   graph documents. The manifest holds each key of `ehos.yaml` as the file has it, `schema` set to
   `ehos.manifest/v9`, and `ehos_yaml` set to `ehos.yaml/v8`. It is the manifest that EHOS writes
   from the same file
   ([`docs/manifest.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/manifest.md) of
   eh-os).
4. If the directory holds an OpenAPI file, `openapi.json`, `openapi.yaml` or `openapi.yml`, `verify`
   puts it into the bundle as it is, and the bundle is `ehos.bundle/v2`. The OpenAPI file describes
   the API of the service, for the developers of the applications that call it. Neither `ehosctl`
   nor EHOS reads the file. `verify` refuses two OpenAPI files, an empty one, and one of more than
   1 MiB.

EHOS also checks rules that the schema cannot give, such as two entries of `serves` with one
port. `ehosctl` does not check these rules. If an installation is chosen, EHOS checks the file and
the manifest as for an application. Then `verify` reads the versions of the name in EHOS:

| EHOS says | `verify` |
| --- | --- |
| It has no application with the name | Says that the first registered build makes the name a utility service. |
| It knows the name as a utility service | Says so, and passes. |
| It knows the name as an application | Exits with 1. EHOS refuses a utility service with the name of an application. |
| You cannot read the versions of the name | Says that it cannot tell, and passes. |

If EHOS does not answer, `verify` exits with 5. The message says that EHOS did not check the file,
and that the bundle is written.

## Exit codes

| Code | When |
| --- | --- |
| 0 | Each gate passed, and EHOS accepted both files or did not check. For a utility service, `ehos.yaml` passed the check of `ehosctl` and the bundle is written. |
| 1 | A gate failed, the application manifest was not written or is larger than EHOS takes, or EHOS refused a file. For a utility service, EHOS knows the name as an application. |
| 2 | The directory has no `mix.exs`, `ehos.yaml` or `.tool-versions` as a regular file. For a utility service, `ehosctl` refused `ehos.yaml`. |
| 5 | EHOS did not answer. |
| 4 | The installation that you named is unknown, before a gate runs. Or your sign-in expired, after the gates. |

## Next steps

- [Builds](builds.md): register the bundle that `verify` wrote.
- [Deploying](deploy.md): deploy the application.
