# Environment templates

EHOS makes each ephemeral environment from an environment template. These commands do what the
console's Environment templates page does. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page, and
[`docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md)
describes the API that they use.

```sh
ehosctl env template create sandbox --default --seed-profile demo
ehosctl env template bind sandbox trial
ehosctl env template update sandbox --quota pods=10,limits.memory=4Gi --limits limits.json
ehosctl env template update sandbox --quota '' --limits ''
ehosctl env template show sandbox
ehosctl env template unbind sandbox postgres
ehosctl env template remove sandbox
```

`list` and `show` need one of the platform capabilities. Each change needs
`ehos.environment.manage`.

## What an environment template holds

- **Resources**: for each kind of need, the resource that an ephemeral environment made from the
  environment template gets. The resource must serve non-production. If it does not, EHOS refuses
  `bind` with `across_the_line`, and `ehosctl` exits with 2.
- **A seed profile**: the seed of each application gets it as `EHOS_SEED_PROFILE`.
- **A quota and limits**, optional. Without them, the quota and the limits of the installation
  apply.
- **Default**: `env create` uses the default environment template when you give no `--template`.

EHOS copies all of it into an environment when it makes the environment. If you change an
environment template, the environments made from it do not change.

## Set a quota and limits

- **`--quota`** gives the `hard` values of a Kubernetes `ResourceQuota` as `key=value` pairs. Each
  key replaces the same key of the quota of the installation.
- **`--limits`** gives a file with the `limits` of a Kubernetes `LimitRange`, as a JSON list. Give
  `-` to read the list from stdin.
- Each value must be at most the ceiling of the installation. If it is more, EHOS refuses it with
  `invalid` and says why, and `ehosctl` exits with 2.
- Give `''` to use the quota or the limits of the installation again. An empty `--seed-profile`
  removes the seed profile.
- If you do not give an option, its value does not change.

## Remove the default

`--no-default` leaves the installation without a default environment template. Until you make
another one the default, EHOS refuses `env create` without `--template` with `no_template`.

## Remove an environment template

If an application keeps a secret as a default in the environment template, EHOS refuses `remove`
with `in_use`. Run `ehosctl env template show <environment template>` to see the applications. Delete each secret first
with `ehosctl secret delete <secret> --app <application> --template <environment template>`.

`env show` shows the quota and the limits that an ephemeral environment got.
