# Sign-in, people, mail and service agreements

EHOS gives an application four things only after a person agrees: a sign-in agreement, a people
agreement, a mail agreement and a service agreement. These commands list, give and withdraw them,
as the console does. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page, and
[`docs/agreements-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/agreements-api.md)
describes the API that they use. EHOS records each of these agreements, each withdrawal and each
refusal, as it records those of the console.

```sh
ehosctl apps sign-in list tax --env production
ehosctl apps sign-in agree tax ledger --env production
ehosctl apps sign-in withdraw tax ledger --env production
ehosctl people agreements
ehosctl people agree ledger --env production
ehosctl people withdraw ledger --env production
ehosctl mail agreements
ehosctl mail agree ledger --env production --level external --reply-domain example.com
ehosctl mail withdraw ledger --env production
ehosctl services list invoice-pdf --env production
ehosctl services agree invoice-pdf ledger --env production
ehosctl services withdraw invoice-pdf ledger --env production
ehosctl services agree-hosts ledger invoice-pdf --env production --host api.office.example:443
ehosctl services withdraw-hosts ledger invoice-pdf --env production
```

## Let the pages of one application get credentials for another

A sign-in agreement lets the pages of one application get credentials for another application in
one environment. The environment tab of the application in the console does the same.

- `apps sign-in list <application> --env <environment>` lists the applications whose pages ask
  for credentials for the application there, and the sign-in agreements.
- `apps sign-in agree <application> <client> --env <environment>` lets the pages of `<client>` get
  the credentials.
- `apps sign-in withdraw <application> <client> --env <environment>` stops it at the next sign-in
  or renewal. A credential already issued expires within 10 minutes.

`agree` and `withdraw` need `ehos.application.deploy` for the application in that environment.
`list` needs `ehos.application.deploy` or `ehos.application.register`.

## Let an application read the people

A people agreement lets the workload of an application read the people of the company in one
environment. The people page of the console does the same. Each command needs
`ehos.people.manage`.

- `people agreements` lists each application that asks, and the people agreements.
- `people agree <application> --env <environment>` lets the application read the people there.
- `people withdraw <application> --env <environment>` makes EHOS refuse its next reading.

## Let an application send mail through EHOS

A mail agreement says how far the workload of an application can send mail through EHOS in one
environment. The Installation page of the console does the same. Each command needs
`ehos.mail.manage`.

- `mail agreements` lists each application that asks, with what it asks and the mail agreement.
- `mail agree <application> --env <environment> --level internal` lets the application send mail
  only to the people of the company. `--level external` lets it send mail to any
  address.
- Each `--reply-domain` names a domain that replies can go to. Use the domains that the
  application names there. Without `--reply-domain`, the mail agreement names no reply domain.
- `mail agree` again changes the mail agreement.
- `mail withdraw <application> --env <environment>` makes EHOS refuse its next message.

The application sends mail only within the mail agreement and within what its deployment there
asks.

## Let an application call a utility service

A service agreement lets one application call one utility service in one environment. The
environment tab of the utility service in the console does the same.

- `services list <name> --env <environment>` lists the service agreements. For a utility service,
  it lists the applications that ask to call it or are agreed to. For an application, it lists the
  utility services that it asks to call or is agreed for, and the variable in which it gets the
  address of each.
  It needs `ehos.application.deploy`, `ehos.application.register` or `ehos.release.approve` for
  that name there.
- `services agree <service> <application> --env <environment>` lets the application call the
  utility service. It needs `ehos.application.deploy` for the utility service there.
- `services withdraw <service> <application> --env <environment>` takes the service agreement
  back. It needs the same capability.

While a service agreement holds, EHOS gives the application the address of the service, and
starts its pods again for it. After a withdrawal, the application cannot open a new connection
to the service.

### Agree to the hosts of a utility service

A utility service can send data to hosts outside the installation. What the application sends the
service can then reach those hosts. If the service names a host in the environment, its service
agreement holds only after the side of the application also agrees. The side of the application is
a person who can approve the releases of the application there.

1. Read the hosts with `services list <application> --env <environment>`. The `HOSTS` column
   gives each host as `host:port`.
2. Agree with `services agree-hosts <application> <service> --env <environment>`, and give each
   host with `--host`. It needs `ehos.release.approve` for the application there.

EHOS refuses the agreement if the hosts are not all the hosts that the service names there now.
Then read the hosts again. `services withdraw-hosts <application> <service> --env <environment>`
takes the agreement of the application back. The application cannot open a new connection to the
service, and the service agreement stays.

If a promotion of the service adds a host, the person who approves it also agrees for each
application with a service agreement there. `ehosctl approve` shows the hosts that the
promotion adds, but not these applications. Read them on the promotion in the console before you
approve it.

## Read the state of a request

The table uses the words of the console:

- **asks**: the deployment asks, and nobody agreed yet.
- **agreed**: the deployment asks, and a person agreed.
- **agreed, no longer asked**: a person agreed, but the deployment no longer asks. It holds for a
  later deployment that asks again, until a person withdraws it.

For a service agreement, the table also says when the utility service has no deployment in the
environment. It also says when the service agreement waits for the side of the application. The
`APPLICATION'S SIDE` column says `not needed` when the service names no host there, `waits`, or
`agreed` with the person who agreed.

For mail, the table shows what the application asks, or `no longer asks`, and the mail agreement,
or `not agreed`.

With `--json`, each request has `asks`, `agreed`, `agreed_at` and `by`. A sign-in request also has
`client`. A people request and a mail request also have `application` and `environment`. For mail,
`asks` and `agreed` are each `{"level", "reply_domains"}` or null. A service request also has
`service`, `application`, `deployed`, `holds` and `variable`. If EHOS gives the side of the
application, a service request also has `hosts`, `application_side` and `application_by`.

## Why EHOS refuses

EHOS gives its refusal in its own words:

- If you do not have the capability, `ehosctl` exits with 3.
- If the deployment of the application there no longer asks (`not_requested`), or there is nothing
  to withdraw, `ehosctl` exits with 1.
- If a mail agreement is wider than the deployment asks (`wider_than_asked`, `domain_not_asked`),
  `ehosctl` exits with 1.
- If the utility service names no host there (`no_hosts`), `services agree-hosts` exits with 1.
- If the hosts are not the hosts that the service names now (`hosts_changed`), it exits with 1.
- If a mail agreement names no level, or more than 8 domains (`invalid`), `ehosctl` exits with 2.
- If the application or the environment does not exist, a people agreement exits with 1.
- For a sign-in agreement, only a person who can deploy across the platform gets exit 1 for a name
  that does not exist. EHOS refuses each other person as for a name that exists, with exit 3. So
  nobody learns a name by trying it.

## Next steps

- [Environments and resources](env.md): the environments of an installation.
- [People](people.md): the people of the company.
