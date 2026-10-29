# Role bindings

```sh
ehosctl role-bindings bind ledger.clerk --to ada@example.com --app ledger --env staging
ehosctl role-bindings bind ehos.people_reader --to ada@example.com --agent month-closer
ehosctl role-bindings bind ledger.clerk ledger.auditor --to ada@example.com --app ledger --env staging
ehosctl role-bindings list
ehosctl role-bindings list --to ada@example.com
ehosctl role-bindings unbind <binding id>
```

These do what the console's Bindings page does
([eh-os `docs/role-bindings-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/role-bindings-api.md)).
Each needs `ehos.role_binding.manage`: anywhere to list, over the binding's scope to bind or
unbind.

- **Who** is a person's email, an agent's owner's email with `--agent` and its name, or an id.
- **Where** is the whole platform without `--app`, an application with `--app`, and one of its
  environments with `--env` too. An application's role is bound in one environment.
- **Several roles** in one place are one request each, in the order given. A role refused by EHOS
  does not stop the rest; not being signed in, or EHOS being unavailable, does, and the rest are
  not asked: the command then exits with that kind (4 or 5), to sign in or wait and run it again.
  Otherwise it exits with the first refusal's kind. What was bound is printed on stdout and each
  refusal on stderr, by its role. With `--json`, stdout holds `role_bindings`, each as one binding
  answers, `refused`, each with its `role`, `kind` and `refusal`, and `not_asked`. A role refused
  as `unreachable` after its request was sent may have been bound: `list` says.
- **`list --to`** shows one person's or agent's bindings. An id works for anyone who may list; an
  email is looked up as `bind` looks it up, which needs `ehos.role_binding.manage`.
- **A platform role** is bound only where you hold every capability it grants, or it is refused,
  `escalation`, exit 3; an agent is never bound more than its owner holds there.
- **The last `ehos.administrator`** of the whole platform is kept: removing it exits 1.
