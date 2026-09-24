# ehos_app

What an application needs to run on EHOS, kept as a dependency so it can be upgraded.

Today that is one Igniter installer, `mix ehos_app.install`, which `ehosctl init` runs on a
fresh Phoenix project. It adds:

- `eh_os_contract` from git, pinned to a tag, with its config, migration and supervision child
  (after the repo and Oban; Oban through its own installer)
- `eh_os_contract.check` in the `precommit` alias
- `ehos.yaml`, the declaration EHOS reads
- `.tool-versions`, pinning the Erlang and Elixir the project was generated with
- the agent harness: an EHOS section at the top of `AGENTS.md`, and `CLAUDE.md` loading it
- a release and a Dockerfile, through `mix phx.gen.release --docker`
- with `--example`, an example contract

Running it again changes nothing.

## Working on it

```sh
mix check
```

To try it on a real project without `ehosctl`:

```sh
mix igniter.new demo --with phx.new --with-args="--database postgres" \
  --install ehos_app@path:$PWD --example --yes
```
