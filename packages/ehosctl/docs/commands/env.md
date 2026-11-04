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

If the name is `<application>-pr-<n>`, `ehosctl` writes a warning on stderr before it creates the
environment. If the repository previews pull requests, the pipeline of that pull request deploys to
the environment. The pipeline can also remove it. Under `--json`, `ehosctl` writes no warning.

In a GitHub Actions job, the credential of the job reaches only the ephemeral environments of its
application. If more than one application trusts the repository, give `--app` to `extend` and
`remove` too. The job then uses the trust of that application.

## Find what holds the maximum number of ephemeral environments

The installation sets the maximum number of ephemeral environments for each application and in
all. If the application or the installation has the maximum, EHOS refuses one more ephemeral
environment. `ehosctl` then exits with 1. After the sentence of EHOS, `ehosctl` lists the ephemeral
environments that count:

```text
ehosctl: This application has the maximum number of ephemeral environments: 3. Remove one, then try again.
These ephemeral environments count toward the maximum of 3:
 ENVIRONMENT   APPLICATION  EXPIRES               BUILD
 ledger-pr-12  ledger       2026-11-05T09:00:00Z  pull request #12: Rooms by floor
 ledger-main   ledger       2026-11-05T10:00:00Z  refs/heads/main
1 more that you can read also counts. Run `ehosctl env list` to see all of them.
Run `ehosctl env remove ENVIRONMENT` to remove one.
```

- The list shows at most 20 environments that you can read. A line under the table says how many
  more that you can read count.
- BUILD is the build that runs in the environment. EHOS does not check what a pipeline states.
  BUILD shows the first of these that the build has:
  1. the number of its pull request and its title, as its pipeline stated them, cut at 60
     characters;
  2. the ref that the token of GitHub named;
  3. a ref that a person stated, followed by `(stated)`;
  4. the id of the build.
- BUILD is `-` if no build runs there, or if you cannot read the builds of its application.
- At the count of the installation, the environments of other applications count too. A person
  with the role `ehos.platform_operator` can remove any of them.
- A pipeline gets a list with its own environment at most. If the list is empty, `ehosctl` writes
  the sentence alone.

Under `--json`, the error has the code `too_many_for_application` or `too_many_ephemeral`. It also
has the list as `cap`, `environments` and `more`, as EHOS gives them
([At the count](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md#at-the-count)).

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
