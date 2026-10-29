# Environments and resources

```sh
ehosctl env create ledger-pr-12 --app ledger --template small --ttl 24h
ehosctl env extend ledger-pr-12 --ttl 72h
ehosctl env remove ledger-pr-12 --confirm ledger-pr-12
ehosctl env create staging --type production
ehosctl resources classify shared-1 non_production
ehosctl env bind staging shared-1
ehosctl env bind staging shared-2 --application ledger
ehosctl env show staging
ehosctl env unbind staging <binding id>
ehosctl env remove staging
```

These do what the console's Environments, environment and Resources pages do
([eh-os `docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md)).
Listing and showing need one of the platform capabilities; creating, extending and removing an
ephemeral environment `ehos.application.deploy` on its application (one made before eh-os D-98,
which belongs to none, is removed with `ehos.environment.manage`); creating a production one
`ehos.environment.manage`, and removing it `ehos.environment.remove_production`, which only the
administrator holds; `bind`, `unbind` and `classify` `ehos.resource.manage`.

- **An environment and a resource** are named by their name; a binding by the id `env show` lists.
- **An ephemeral environment** belongs to the application `--app` names, is made from
  `--template` (the installation's default without one) and expires after `--ttl` (`90m`, `24h`,
  `7d`; the installation's default without one, at most its maximum) unless `env extend` gives it
  longer, from now (eh-os D-98). `--ttl` is at least a minute. `env list` and `env show` print its
  application, template and expiry. A GitHub Actions job's credential reaches these and no other
  environment (eh-os D-110); in a job, `extend` and `remove` take `--app` too, which the job's
  exchange names where its repository is trusted by more than one application.
- **Removing** an ephemeral environment takes it down whole, its deployments withdrawn and its data
  dropped (eh-os D-100), and every removal gives the environment's name again: typed when
  `env remove` asks on a terminal, or as `--confirm <name>`. Without a terminal nothing is asked,
  so without `--confirm` nothing is sent, exit 2, as for a name given wrong.
- **`--type`** is `production` or `ephemeral`: a production environment binds only resources
  serving production, any other only non-production ones (eh-os D-57), and a bind across that line
  is refused, `across_the_line`, exit 2.
- **A resource's class** is set once; setting it again exits 1, `already_set`.
- **Registering a resource** is not a command: it stays a platform operation.
- **A change that went unanswered** may have been done: the error says so, and `env show` tells.
