# Environments and resources

These commands create and remove the environments of an installation, and bind resources in them.
They do what the Environments, environment and Resources pages of the console do. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page, and
[`docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md)
describes the API that they use.

```sh
ehosctl env create ledger-pr-12 --app ledger --template small --ttl 24h
ehosctl env extend ledger-pr-12 --ttl 72h
ehosctl env remove ledger-pr-12 --confirm ledger-pr-12
ehosctl env create staging --type production
ehosctl resources classify shared-1 non_production
ehosctl env bind staging shared-1
ehosctl env bind staging shared-2 --application ledger
ehosctl env show staging
ehosctl env unbind staging <resource binding id>
ehosctl env remove staging
```

## Who can do what

| Command | Capability that it needs |
| --- | --- |
| `env list`, `env show`, `resources list` | One of the platform capabilities. |
| `env create`, `env extend`, `env remove` of an ephemeral environment | `ehos.application.deploy` on the application of the environment. |
| `env create` of a production environment | `ehos.environment.manage`. |
| `env remove` of a production environment | `ehos.environment.remove_production`. Only the role `ehos.administrator` grants it. |
| `env bind`, `env unbind`, `resources classify` | `ehos.resource.manage`. |

An ephemeral environment that an older version of EHOS made belongs to no application. To remove
it, you need `ehos.environment.manage`.

## Create an ephemeral environment

An ephemeral environment belongs to one application. People use it to try a version of that
application.

1. Run `ehosctl env create <name> --app <application>`.
2. Optional: give `--template` to choose the environment template. Without it, EHOS uses the
   default environment template of the installation.
3. Optional: give `--ttl` to choose when the environment expires, such as `90m`, `24h` or `7d`.
   Without it, EHOS uses the default of the installation. The minimum is 1 minute. The maximum is
   the maximum of the installation.

`ehosctl` shows the name, the application, the environment template and the time when the
environment expires. `env list` and `env show` show the same.

To give the environment more time, run `ehosctl env extend <name>`. The new time counts from now.

In a GitHub Actions job, the credential of the job reaches only the ephemeral environments of its
application. If more than one application trusts the repository, give `--app` to `extend` and
`remove` too. The job then uses the trust of that application.

## Create a production environment

Run `ehosctl env create <name> --type production`. Then bind its resources.

The type of an environment decides which resources it can bind. A production environment binds
only resources that serve production. Another environment binds only resources that do not serve
production. If you bind a resource across that line, EHOS refuses with `across_the_line`, and
`ehosctl` exits with 2.

## Bind a resource in an environment

1. Run `ehosctl resources list` to see the resources and what each serves.
2. If a resource has no class, run `ehosctl resources classify <resource> production` or
   `non_production`. You can set the class only once. If you set it again, EHOS refuses with
   `already_set`, and `ehosctl` exits with 1.
3. Run `ehosctl env bind <environment> <resource>`. The resource binding is the default for the
   kind of the resource.
4. To bind a resource for one application only, add `--application <application>`. EHOS gives the
   application its own schema in the resource.

`ehosctl` shows the id of the resource binding. `env show` shows each resource binding with its id.

To remove a resource binding that no deployment has used, run
`ehosctl env unbind <environment> <resource binding id>`.

Registering a resource is not a command of `ehosctl`. The installation administrator registers it
on the server.

## Remove an environment

Run `ehosctl env remove <name>`. `ehosctl` asks you to type the name of the environment again.
If you type another name, `ehosctl` removes nothing and exits with 2.

Where nobody can type, as in a GitHub Actions job or a pipe, `ehosctl` does not ask. Give
`--confirm <name>`. Without it, `ehosctl` sends nothing and exits with 2.

EHOS takes an ephemeral environment down whole: it withdraws its deployments and drops its data.

## What to do when EHOS does not answer

If EHOS does not answer after `ehosctl` sent a change, EHOS can have made the change. The error
says so. Run `ehosctl env show <name>` to see.

## Next steps

- [Environment templates](env-template.md): the environment templates that ephemeral
  environments are made from.
- [Quota and limits](env-quota.md): the quota and limits of an environment.
- [Secrets](secret.md): the secrets of an application in an environment.
