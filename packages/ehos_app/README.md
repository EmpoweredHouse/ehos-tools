# ehos_app

What a Phoenix application needs in order to run on [EHOS](https://github.com/EmpoweredHouse/eh-os),
as a dependency the application keeps.

Today that is one [Igniter](https://hexdocs.pm/igniter/readme.html) installer, `mix ehos_app.install`.
It turns a fresh Phoenix project into an EHOS application. It is normally run for you by
[`ehosctl init`](../ehosctl/README.md), but it works on its own too.

The runtime side will land here as EHOS defines it: verifying EHOS-issued credentials, and the health
and specification endpoints. An application then upgrades it the same way it gets everything else
from the template:

```sh
mix igniter.upgrade ehos_app
```

## What the installer does

| Change | Where | Why |
| --- | --- | --- |
| Adds [`eh_os_contract`](https://github.com/EmpoweredHouse/eh-os-contract), from git and pinned to a tag | `mix.exs` | The contract engine: declared business events, their log, and the conformance check. It is not on Hex yet, and lives in a subdirectory, hence `sparse:` |
| Installs Oban through Oban's own installer | `mix.exs`, `config/`, a migration, `application.ex` | The engine runs asynchronous handlers as Oban jobs. Oban's setup stays Oban's to change |
| Configures the engine with the application and its repo | `config/config.exs` | `config :eh_os_contract, applications: [...], repo: ...` |
| Generates the engine's migration after Oban's | `priv/repo/migrations/` | Its jobs run on Oban's tables. Both installers run in the same second, so the timestamp is chosen explicitly |
| Starts `EhOsContract` after the repo and Oban, before the endpoint | `lib/<app>/application.ex` | At boot it records the deployed contract version through the repo |
| Adds `eh_os_contract.check` to `mix precommit` | `mix.exs` | Whole-program contract checks the compiler cannot make |
| Writes `ehos.yaml` | project root | What the application needs from EHOS, never how: no hosts, no secrets, no Kubernetes |
| Writes `.tool-versions` | project root | The Erlang and Elixir the project was generated with, read by both mise and asdf |
| Puts an EHOS section at the top of `AGENTS.md`, and writes `CLAUDE.md` loading it | project root | Coding agents read the EHOS rules before Phoenix's own |
| Runs `mix phx.gen.release --docker` | `Dockerfile`, `rel/`, `lib/<app>/release.ex` | A release image, as the project's own Phoenix version generates it |
| With `--example`, writes an example contract | `lib/<app>/contracts/case_handling.ex` | So the check and the conformance report have something to read on day one |

A second run changes nothing, and a test pins that. Files the installer creates (`ehos.yaml`,
`.tool-versions`, `CLAUDE.md`, the contract) are never overwritten. The `AGENTS.md` section is
recognised by its marker and added only once.

## Using it without `ehosctl`

The `github:` source below assumes `ehos_app` has a repository of its own, because Igniter cannot
install from a subdirectory. That repository does not exist yet. Until it does, use
`ehos_app@path:<absolute path to this directory>`.

On a new project:

```sh
mix igniter.new shop --with phx.new --with-args="--database postgres" \
  --install ehos_app@github:EmpoweredHouse/ehos_app --example --yes
```

On an existing Phoenix project with Igniter:

```sh
mix igniter.install ehos_app@github:EmpoweredHouse/ehos_app
```

### Options

| Option | Effect |
| --- | --- |
| `--example` | Also generate the example contract |

## What is decided, and what is guessed

The contract engine's wiring follows its
[README](https://github.com/EmpoweredHouse/eh-os-contract/blob/main/packages/eh_os_contract/README.md),
and the release follows Phoenix. What the template says about EHOS follows the EHOS
[architecture](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ARCHITECTURE.md) (§5.1). EHOS
does not read `ehos.yaml` yet, though, and has not fixed the environment an application runs in.
Until it does, three things in the generated project are guesses:

- the fields of `ehos.yaml`;
- the health endpoints, which `ehos.yaml` names but the template does not serve yet;
- the environment variables, which are Phoenix's own (`DATABASE_URL`, `PORT`).

They are listed, with the other open points, in [docs/spike.md](../../docs/spike.md).

## Development

```sh
mix check
```

The tests run the installer on `Igniter.Test.phx_test_project/1`, a Phoenix project held in memory,
and assert what it creates and patches. The files the installer writes are EEx templates in
[`priv/templates/ehos_app.install/`](priv/templates/ehos_app.install).

Igniter is an optional dependency, which is the convention for installers. The installer compiles
only where Igniter is present, and an application depending on `ehos_app` at runtime does not
inherit Igniter.

Changes are recorded in [CHANGELOG.md](CHANGELOG.md). Raise the version whenever what the installer
writes changes: `mix igniter.upgrade` compares it to decide which upgrade steps to run.
