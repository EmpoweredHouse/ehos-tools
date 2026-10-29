# An environment's own quota

```sh
ehosctl env quota show production
ehosctl env quota set production --quota limits.memory=8Gi,requests.memory=8Gi
ehosctl env quota set production --limits limits.json
ehosctl env quota clear production
```

These do what the console's environment page does for its quota
([eh-os `docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md),
"An environment's own quota", D-143). Showing needs one of the platform capabilities, and setting
`ehos.environment.manage`; EHOS records each change as `environment_quota.set`.

- **`--quota` and `--limits`** are written as for a [template](env-template.md): the quota merged key by key
  over the installation's, the limits replacing the installation's for each resource they name.
  A flag left out keeps what the environment has, one given as `''` gives it back to the
  installation, and `clear` gives back both.
- **Within the ceiling**: a quota above the installation's `environments.ceiling`, or limits that
  give a container a CPU limit, are refused, `invalid`, exit 2, with EHOS's reason.
- **A quota below what is deployed** is taken: what runs keeps running, and `set` warns which
  applications' next deployment there no longer fits, refused `no_room` until the quota or what
  they ask for changes (`no_longer_fit` under `--json`).
- **An ephemeral environment**'s quota is its template's: setting it is refused, `ephemeral`,
  exit 2. Change the template instead.
