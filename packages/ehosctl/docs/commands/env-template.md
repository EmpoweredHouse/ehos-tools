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
ehosctl env template role-entry set sandbox office.reviewer --app office --to ada@example.com
ehosctl env template people agree sandbox --app office
```

`list` and `show` need one of the platform capabilities. Each change needs
`ehos.environment.manage`. The role entries and the people agreement need other capabilities: see
their sections.

## What an environment template holds

- **Resources**: for each kind of need, the resource that an ephemeral environment made from the
  environment template gets. The resource must serve non-production. If it does not, EHOS refuses
  `bind` with `across_the_line`, and `ehosctl` exits with 2.
- **A seed profile**: the seed of each application gets it as `EHOS_SEED_PROFILE`.
- **A quota and limits**, optional. Without them, the quota and the limits of the installation
  apply.
- **Default**: `env create` uses the default environment template when you give no `--template`.
- **Role entries and a people agreement**, for each application: who gets a role in its
  ephemeral environments, and if it can read the people there.

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
with `in_use`. Run `ehosctl env template show TEMPLATE` to see the applications. Delete each secret first
with `ehosctl secrets delete SECRET --app APPLICATION --template TEMPLATE`. Replace each word in
capitals with its name.

`env show` shows the quota and the limits that an ephemeral environment got.

## Give people a role in advance

A role entry is a person and a role of one application. The environment template holds it for the
ephemeral environments of that application made from the environment template. EHOS makes each role
entry into a role binding in such an environment. You need `ehos.role_binding.manage` over the
application.

```sh
ehosctl env template role-entry set sandbox office.reviewer --app office --to ada@example.com
ehosctl env template role-entry list sandbox --app office
ehosctl env template role-entry remove sandbox <role entry id> --app office
```

- **`--to`** is the email or the id of the person. The person must be invited and not disabled. A
  role entry cannot name an agent.
- **The role** is a role of the application, written `APPLICATION.NAME`. If it is a platform role
  or a role of another application, EHOS refuses it with `platform_role` or `wrong_application`,
  and `ehosctl` exits with 2.
- An environment template holds at most 200 role entries for each application. After that, EHOS
  refuses `set` with `too_many_entries`, and `ehosctl` exits with 1.
- `list` shows the id of each role entry. Give it to `remove`.

## Give a people agreement in advance

A people agreement lets an application read the people of the company in an environment. Give one
in advance on an environment template, for the ephemeral environments of the application made from
it. You need `ehos.people.manage` at the whole platform.

```sh
ehosctl env template people agree sandbox --app office
ehosctl env template people show sandbox --app office
ehosctl env template people withdraw sandbox --app office
```

`agree` again changes nothing. If the environment template holds no people agreement for the
application, EHOS refuses `withdraw` with `not_found`, and `ehosctl` exits with 1.

## Copy a utility service into the previews of an application

A service entry names a utility service that the ephemeral environments of one application get a
copy of. The copy comes from the version of the service in force in a production environment, the
source. EHOS makes the copy when it deploys the application in such an environment, if the version
of the application asks for the service.

The person who may deploy the service sets and removes the entry. You need
`ehos.application.deploy` over the utility service.

```sh
ehosctl env template service-entry set sandbox invoice-pdf --app office --source production
ehosctl env template service-entry list sandbox --app office
ehosctl env template service-entry remove sandbox invoice-pdf --app office
```

If the service sends data to hosts outside the installation, a person who may approve the releases
of the application must agree to those hosts. You need `ehos.release.approve` over the application.
Until then, the entry copies nothing. The ephemeral environments run builds that no person reviewed,
and the copy sends their data to these hosts.

```sh
ehosctl env template service-entry agree sandbox invoice-pdf --app office --host api.office.example.org:443
ehosctl env template service-entry withdraw sandbox invoice-pdf --app office
```

- **`--source`** is a production environment. If it is not, EHOS refuses `set` with
  `not_production`, and `ehosctl` exits with 1.
- **`--host`** is a host that `list` shows, as `HOST:PORT`. Give it once for each host. If the
  hosts are not all the hosts that the service names now, EHOS refuses `agree` with
  `hosts_changed`, and `ehosctl` exits with 1. Run `list` and agree again.
- If the service names a host that the application did not agree to, `list` shows the application's
  side as `waiting`.
- If you remove an entry, a copy already in an ephemeral environment stays until the next
  deployment of the application there.
- An environment template that holds a service entry cannot be removed.

## Make an environment without them

Give `--no-role-bindings` to `ehosctl env create` or to `ehosctl deploy --create-env`. The new
ephemeral environment then gets no role binding from the role entries and no people agreement from
the environment template. One flag leaves out both.

An EHOS that does not yet give them to environments keeps them on the environment template.
`ehosctl env show` says when an environment has no role bindings and no people agreement from its
environment template.
