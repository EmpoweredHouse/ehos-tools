# The audit record, your activity and your agents

These commands read the audit record and your own activity, and manage your agents. They show
what the Audit, My activity and My roles pages of the console show. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page, and
[`docs/audit-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/audit-api.md)
describes the API that they use.

```sh
ehosctl audit --limit 500
ehosctl activity
ehosctl agents create month-closer
ehosctl agents list
```

## Read the audit record

`audit` lists the decisions of EHOS, allowed and refused, in each place where you hold
`ehos.audit.read`. At the whole platform, that is each decision. For an application, that is the
decisions about that application. EHOS records a refused reading too.

## Read your own activity

`activity` lists what was done in your name or in the name of your agents, allowed and refused. It
needs no capability.

## Read more rows

`audit` and `activity` show the newest decision first. They read the pages of EHOS up to `--limit`
rows. The default is 100, and the maximum is 10,000. If older rows remain, `ehosctl` says so.
With `--json`, `ehosctl` gives each row whole, with its details.

## Create an agent

Run `ehosctl agents create <name>`. An agent holds nothing until a person binds a role to it, with
`ehosctl role-bindings bind … --agent <name>`. An agent never gets more than you hold in that
place. You can have up to 200 agents. If you already use the name, `ehosctl` exits with 2.

## Next steps

- [Role bindings](role-bindings.md): bind roles to you and to your agents.
