# Agreements

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
```

Three things EHOS gives an application only once someone agrees, as the console agrees to them,
through EHOS's API
([eh-os `docs/agreements-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/agreements-api.md)).
EHOS records every agreement and withdrawal, and every refusal of one, as it records the
console's.

- **Sign-in** (eh-os D-70): another application's pages getting credentials for an application in
  an environment, as the application's environment tab agrees. `apps sign-in list <app>` lists the
  applications whose pages ask for credentials for it there, and those agreed to;
  `agree <app> <client>` lets the pages of `<client>` get them, and `withdraw` stops it at their
  next sign-in or renewal, while a credential already issued lives out its ten minutes. Agreeing
  and withdrawing need `ehos.application.deploy` for the application there; listing needs that or
  `ehos.application.register`.
- **The people** (eh-os D-81): an application's workload reading the company's people in an
  environment, as the people page agrees. `people agreements` lists every application that asks,
  and those agreed to; `people agree <app>` lets it read them there, and `people withdraw <app>`
  refuses its next reading. Each needs `ehos.people.manage`.
- **Mail** (eh-os D-140): how far an application's workload may send mail through EHOS in an
  environment, as the console's Installation page agrees. `mail agreements` lists every application
  that asks, with what it asks and the agreement given; `mail agree <app> --level internal` lets it
  write to people in EHOS's directory only, `--level external` to any address, and each
  `--reply-domain` names a domain the answers may go to, among those it names (none when left out).
  Agreeing again changes the agreement. `mail withdraw <app>` refuses its next message. What it
  sends stays within both the agreement and what its deployment there asks. Each needs
  `ehos.mail.manage`.
- **The state** is the console's: `asks`, `agreed`, or `agreed, no longer asked` for an agreement
  that outlasted the deployment that asked for it, and holds for a later one that asks again until
  it is withdrawn. Under `--json`, each request's `asks`, `agreed`, `agreed_at` and `by`, with
  `client` for sign-in and `application` and `environment` for the people and for mail. For mail,
  `asks` and `agreed` are each `{"level", "reply_domains"}` or null, and the table says what the
  application asks, or `no longer asks`, and the agreement, or `not agreed`.
- **Refusals** are EHOS's sentences: 403 when you may not (exit 3), and exit 1 when the
  application's deployment there no longer asks (`not_requested`), or when there is no agreement
  to withdraw. A mail agreement wider than the deployment asks is exit 1 (`wider_than_asked`,
  `domain_not_asked`), and one that names no level or more than 8 domains exit 2 (`invalid`). An application or environment that is none is exit 1 for the people. For sign-in it
  is exit 1 only for someone who may deploy across the platform; anyone else is refused as for one
  that exists, exit 3, so a name is not learnt by trying it.
