# Role bindings

A role binding gives a role to a person or an agent in one place: the whole platform, one
application, or one environment of an application. These commands do what the console's Role
bindings page does. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page, and
[`docs/role-bindings-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/role-bindings-api.md)
describes the API that they use.

```sh
ehosctl role-bindings roles
ehosctl role-bindings bind ledger.clerk --to ada@example.com --app ledger --env staging
ehosctl role-bindings bind ehos.people_reader --to ada@example.com --agent month-closer
ehosctl role-bindings bind ledger.clerk ledger.auditor --to ada@example.com --app ledger --env staging
ehosctl role-bindings bind ehos.data_reader --to ada@example.com --app office --env production \
  --for 4h --reason "to check the invoices of ticket 4711"
ehosctl role-bindings list
ehosctl role-bindings list --to ada@example.com
ehosctl role-bindings unbind 5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d
```

## See what each platform role is for

`roles` shows each platform role in the words of EHOS: what the role is for, the other roles that
it includes, where you can bind it, and each capability that it grants. Each person and agent that
is signed in can run it. `ehosctl` keeps no copy of these words, so they are always the words of
the installation.

If a role includes another role, the other role adds nothing in the same place or in a place
inside it.

To see the roles bound to you and to your agents, run `ehosctl roles`.

## Bind roles

`bind` needs `ehos.role_binding.manage` in the place of the role binding. A platform role also
needs each capability that it grants in that place. If you do not hold them, EHOS refuses the role
binding with `escalation`, and `ehosctl` exits with 3.

- **Who**: the email of a person, the email of the owner of an agent with `--agent` and the name of
  the agent, or an id. An agent never gets more than its owner holds in that place.
- **Where**: without `--app`, the whole platform. With `--app`, the application. With `--app` and
  `--env`, one environment of the application. A role of an application needs an environment.
- **Several roles**: `ehosctl` sends one request for each role, in the order that you give.
  - If EHOS refuses a role, `ehosctl` sends the next role.
  - If your sign-in has expired or EHOS does not answer, `ehosctl` stops and exits with 4 or 5.
    Sign in or wait, and then run the command again.
  - Otherwise `ehosctl` exits with the kind of the first refusal.
  - The role bindings that EHOS made go to stdout. Each refusal goes to stderr, after its role.
  - With `--json`, stdout holds `role_bindings`, `refused` (each with its `role`, `kind` and
    `refusal`) and `not_asked`.
  - If EHOS did not answer after `ehosctl` sent a role, EHOS can have bound it. Run `list` to
    see.

## Bind a role to the data of a production environment

A role binding of `ehos.data_reader` or `ehos.data_writer` in a production environment lets a
person or an agent read or change the data of that environment. This includes the personal data of
its people. Such a role binding has an end and a reason, so the access does not stay after the
work is done:

- **`--for`** sets how long the role binding lasts, in hours or days, such as `4h` or `7d`. If you
  give none, the default time of the installation applies. The installation also sets the longest
  time. By default, they are 24 hours and 7 days.
- **`--reason`** says why the person needs the access, in one line of 10 to 500 characters. EHOS
  needs a reason. If you give none and `ehosctl` runs at a terminal, `ehosctl` asks for it. Without
  a terminal, the command fails and tells you to give `--reason`.

`ehosctl` sends `--for` and `--reason` only with `ehos.data_reader` and `ehos.data_writer`. If you
name other roles in the same command, `ehosctl` binds them without an end and a reason. If you name
neither of the two roles, `ehosctl` refuses the two flags and exits with 2.

`bind` shows when the role binding ends and its reason. When the role binding ends, EHOS removes
it, and it grants nothing more.

To keep the access, bind the same role to the same person in the same environment again before it
ends. EHOS changes the end and the reason of the role binding that is there. `ehosctl` says that
the role binding was extended or shortened, and shows the new end. If the end has passed already,
`ehosctl` says that it bound the role. To end the access earlier, bind
it again with a shorter `--for`, or remove the role binding.

EHOS refuses these role bindings with a reason, and `ehosctl` exits with 2:

- `reason_required`: the role binding has no reason.
- `invalid_reason`: the reason is not one line of 10 to 500 characters, or it has a control or
  invisible character.
- `invalid_duration`: the time is less than 1 hour, or more than the longest time of the
  installation. The refusal gives the longest time in seconds.
- `not_expiring`: you gave `--for` or `--reason` for a role binding outside a production
  environment, which has no end.

A data session in that environment ends no later than the role binding. See
[Data sessions](db.md).

## List role bindings

`list` shows the role bindings in each place where you hold `ehos.role_binding.manage`.
`list --to` shows the role bindings of one person or agent. An id works for each person who can
list. An email needs `ehos.role_binding.manage`, because `ehosctl` looks it up as `bind` does.

If a role binding has an end or a reason, the ENDS and REASON columns show them. Only a role
binding of `ehos.data_reader` or `ehos.data_writer` in a production environment has them.

The NOTE column says what is special about a role binding:

- **ended**: the end of the role binding has passed, so it grants nothing. EHOS removes it soon.

- **gone**: the version in force no longer has the role, so the role binding grants nothing.
- **beyond its owner**: the role of an agent grants more than its owner holds there. The agent
  gets only the capabilities that its owner holds there.
- **adds nothing**: another role binding of the same person or agent includes this role there.
  You can remove this role binding. The other role binding still grants what it grants.
- **granted by**: a person gave the role through their application, under the rule of one of their
  roles.

## Remove a role binding

`unbind` removes the role binding with the id that `list` shows. EHOS keeps the last
`ehos.administrator` of the whole platform: if you try to remove it, `ehosctl` exits with 1.
