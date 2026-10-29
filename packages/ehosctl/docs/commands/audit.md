# The audit record, your activity and your agents

```sh
ehosctl audit --limit 500
ehosctl activity
ehosctl agents create month-closer
ehosctl agents list
```

These read what the console's Audit, My activity and My roles pages show
([eh-os `docs/audit-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/audit-api.md)).

- **`audit`** needs `ehos.audit.read`, and lists the decisions inside the scopes where you hold
  it: at the whole platform every one, for an application that application's. A refused read is
  recorded.
- **`activity`** lists what was done in your name or your agents', allowed and refused, and needs
  no capability.
- **Both** print the newest first, follow EHOS's pages up to `--limit` rows (100 unless given, at
  most 10,000), and say when older rows remain; `--json` gives each row whole, its details
  included.
- **An agent** holds nothing until a role is bound to it, with `ehosctl role-bindings bind
  … --agent <name>`, and never more than you hold there. You have at most 200; a name you have
  used already exits 2.
