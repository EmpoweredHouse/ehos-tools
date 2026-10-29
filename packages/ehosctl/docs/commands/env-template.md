# Templates

```sh
ehosctl env template create sandbox --default --seed-profile demo
ehosctl env template bind sandbox trial
ehosctl env template update sandbox --quota pods=10,limits.memory=4Gi --limits limits.json
ehosctl env template update sandbox --quota '' --limits ''
ehosctl env template show sandbox
ehosctl env template unbind sandbox postgres
ehosctl env template remove sandbox
```

These do what the console's Templates page does
([eh-os `docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md),
"Templates", D-98). Listing and showing need one of the platform capabilities, and every change
`ehos.environment.manage`.

- **A template** names, for each kind of need, the resource an ephemeral environment made from it
  gets, which serves non-production (`bind` refuses another, `across_the_line`, exit 2); the seed
  profile its applications' seeds are given; and whether it is the installation's default, which
  `env create` uses without `--template`. All of it is copied into an environment when it is made,
  so a change to a template moves no environment.
- **`--quota`** is a `ResourceQuota`'s `hard` as `key=value` pairs, over the installation's key by
  key; **`--limits`** a file holding a `LimitRange`'s `limits` as a JSON list, or `-` for stdin.
  Each is at most the installation's ceiling, else EHOS refuses it, `invalid`, exit 2, saying why.
  `''` gives either back to the installation, and an empty `--seed-profile` clears the profile. A
  flag left out leaves its field as it is.
- **`--no-default`** leaves the installation with no default until another is made one; an
  `env create` without `--template` is then refused, `no_template`.
- **Removing** a template that holds an application's secret as a default is refused, `in_use`:
  delete those first with `ehosctl secret delete <secret> --app A --template T` for each.
- **`env show`** prints the quota and limits an ephemeral environment was given.
