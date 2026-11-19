# ehos_platform

The code that makes the server under an EHOS installation and installs EHOS on it. Two programs
share it ([eh-os D-92](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0092-the-installation-code-is-a-package-in-ehos-tools-and-ehos-s-release-carries-the-chart-and-modules-it-installs.md)):

- **eh-os's own tooling.** `mix ehos.server`, `mix ehos.install` and `mix ehos.cluster` bring up a
  developer's cluster or a server. CI's Cluster job installs every pull request's EHOS with it.
- **`ehosctl`'s platform plane.** `ehosctl server`, `ehosctl install` and `ehosctl server invite`
  are what an operator runs to make and keep an installation
  ([eh-os D-87](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0087-ehosctl-is-one-tool-for-the-developer-and-the-operator-with-a-governed-plane-through-the-api-and-a-platform-plane-outside-it.md)).

So a server made by one is reached and upgraded by the other: the state, the tunnel and what is
installed are kept in one place, `~/.ehos/<name>`, the same way for both. The package depends on
nothing of EHOS's, and EHOS's code does not depend on it.

## What it does

| Module | For |
| --- | --- |
| `EhosPlatform.Server` | The server: made, resized and removed from a provider's OpenTofu module (Oracle Cloud, AWS, GCP or OVHcloud, `EhosPlatform.Server.Provider`), with k3s installed by cloud-init on its first boot. Its state is encrypted under a passphrase, and Kubernetes's API is reached through an SSH tunnel, never opened to the internet. |
| `EhosPlatform.Install` | EHOS on a cluster: the prerequisites (CloudNativePG, cert-manager, trust-manager, Traefik) at pinned versions, the installation's own CA, and EHOS's chart with its image by digest. `invite/1` runs EHOS's release command that invites a person and returns their sign-in link. |
| `EhosPlatform.Source` | What is installed: an eh-os checkout (`checkout/1`), or what a release's `release.json` names (`release/1`), its chart by digest and its OpenTofu modules checked by SHA-256. |
| `EhosPlatform.Tools` | The versions of `tofu`, `helm` and `kubectl` EHOS is tested with, for a caller that can choose which it runs. |

A command of `EhosPlatform.Server` (`up/1`, `tunnel/1`, `status/1`, `down/1`) and
`Install.server/1` return `{:ok, report}`, an `EhosPlatform.Report` that holds the outcome, the
values, what another program printed and the next commands as parts, so that the caller gives each
part its own shape. A refusal is `{:error, message}`, a sentence an operator can act on. When
`tofu`, `helm`, `kubectl` or `ssh` failed and printed something, `message` is an
`EhosPlatform.Failure`, which holds that sentence and, apart, what the program printed. What is
happening along the way is given to `opts[:progress]` as an `t:EhosPlatform.Report.event/0`: a
step, a wait, a warning, or what another program printed. It says nothing unless given. A caller's
mistake, such as no `:source`, raises instead.

## Depending on it

It is released by tags, `ehos_platform-vX.Y.Z`, each with a GitHub release; its `CHANGELOG.md`
says what each changed. It is not on Hex: a project depends on the commit a tag names, from this
repository's subdirectory.

```elixir
{:ehos_platform, "~> 0.18.2",
 github: "EmpoweredHouse/ehos-tools",
 sparse: "packages/ehos_platform",
 ref: "<the commit ehos_platform-v0.18.2 names>"}
```

The programs it runs are the machine's: `tofu`, `helm` and `kubectl` at the versions
`EhosPlatform.Tools` lists, and the system's `ssh` and `sh`. The provider's credentials stay where
its own tools keep them (`~/.oci/config`, an AWS profile, Google's Application Default
Credentials, OpenStack's `clouds.yaml`); none is written into the installation.

## An example

An installation named `trial`, on Oracle Cloud, from an eh-os checkout. The state's passphrase is
`EHOS_STATE_PASSPHRASE`, the key the operator logs in with the one `up` recorded, else
`~/.ssh/ehos_oci`, and the token that pulls EHOS's image `GHCR_TOKEN`, each unless the options give
another.

```elixir
source = EhosPlatform.Source.checkout("/src/eh-os")
opts = [name: "trial", source: source, progress: &IO.inspect/1]

with {:ok, made} <- EhosPlatform.Server.up([provider: "oci"] ++ opts),
     {:ok, _open} <- EhosPlatform.Server.tunnel(opts),
     {:ok, installed} <- EhosPlatform.Install.server([digest: "sha256:…"] ++ opts) do
  IO.puts(made.outcome)
  IO.puts(installed.outcome)
end
```

`EhosPlatform.Server.down/1` removes what `up/1` made and keeps the state, so `up/1` can make the
server again. Each function's options are in its documentation.

## Ways out, and testing a caller

Everything that leaves the process goes through a behaviour, and a caller names the
implementation in `opts`
([T-20](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)):

| Option | Behaviour | Default |
| --- | --- | --- |
| `:runner` | `EhosPlatform.CommandRunner`: a program, `tofu`, `ssh`, `helm`, `kubectl` | `EhosPlatform.CommandRunnerImpl`, `System.cmd/3` |
| `:env` | `EhosPlatform.Env`: the process environment and the operator's home directory | `EhosPlatform.EnvImpl`, `System.get_env/1` and `System.user_home!/0` |
| `:clock` | `EhosPlatform.Clock`: waiting between checks | `EhosPlatform.ClockImpl`, `Process.sleep/1` |
| `:public_address` | `EhosPlatform.PublicAddress`: this machine's address on the internet | `EhosPlatform.PublicAddressImpl`, over HTTPS |

`ehosctl` gives its own `:runner`, which runs the pinned tools through mise. A caller's tests give
mocks, so they run no program, read no environment, wait for nothing and reach no network. With
[Hammox](https://hex.pm/packages/hammox), which also checks each call against the behaviour's
types:

```elixir
# test/test_helper.exs
Hammox.defmock(MyTool.RunnerMock, for: EhosPlatform.CommandRunner)
Hammox.defmock(MyTool.EnvMock, for: EhosPlatform.Env)

# a test
Hammox.stub(MyTool.EnvMock, :get, fn "EHOS_STATE_PASSPHRASE" -> "a passphrase for tests" end)

assert EhosPlatform.Server.passphrase(env: MyTool.EnvMock) == "a passphrase for tests"
```

A path is never a way out: `:home` says where installations are kept, so a test gives a
temporary directory. A path from `~/`, as the defaults `~/.ehos` and `~/.oci/config` are, is under
the home directory that `EhosPlatform.Env.home/1` gives: `HOME` when it is an absolute path of
printable characters without `..`, else the `user_home/0` of `:env`. A test that stubs
`user_home/0` and `get/1` says where that is.

## Working on it

```sh
cd packages/ehos_platform
mix check   # audit, format, warnings as errors, Credo, tests, Dialyzer, docs
mix docs    # this documentation, into doc/
```

The tests mock the behaviours above, so they reach no cloud, cluster or network. A few run a local
program: `CommandRunnerImpl`'s own test runs `sh` and `ps`, and others run `git`, `tar`, `mkfifo` or
`ssh-keygen -l` to make or read a fixture. The rules for code and tests are the repository's
([`CONTRIBUTING.md`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/CONTRIBUTING.md)), and a
change an operator or a caller can see gets a line in `CHANGELOG.md`. A release is the
`ehos-dev:release` skill's, as for every package here
([releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)).
