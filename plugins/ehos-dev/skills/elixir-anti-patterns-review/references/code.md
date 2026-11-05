<!--
  SPDX-License-Identifier: Apache-2.0
  SPDX-FileCopyrightText: 2021 The Elixir Team
  Modified: condensed and adapted for the Shugyo backend, then for EHOS applications, then for
  EHOS's own libraries, CLI and platform.
-->

# Code patterns

## Dynamic atom creation

Trace `String.to_atom/1`, `List.to_atom/1`, and dynamic module names back to input. An unbounded
input vocabulary can exhaust the VM's atom table. Prefer string keys or an explicit allowlist:

```elixir
case params["order"] do
  "asc" -> {:ok, :asc}
  "desc" -> {:ok, :desc}
  _ -> {:error, :invalid_order}
end
```

`String.to_existing_atom/1` prevents new atoms but accepts any existing atom and raises for
unknown strings; it is not a substitute for domain validation. Fixed developer-owned atoms are fine.

## Complex `else` clauses in `with`

Check whether unrelated steps return indistinguishable failures that `else` mislabels. Normalize
the reason at the failing operation, then compose tagged results. A long `with` or a thin controller
using `with` is not itself defective. Do not extract one-use wrappers just to shorten a function.

## Non-assertive map access and pattern matching

Use `row.field` or `%{field: value}` for required, already validated internal fields. Optional
JSON input can use `params["field"]` or `Map.get/3`; required external fields need validation with
an error result, not a newly introduced crash. Match documented `{:error, reason}` results rather
than `_` where a catch-all would silently swallow a new outcome.

Inside a transaction, an expected write failure must roll back with its reason. A function
given to `Repo.transact/2` returns it, and the error rolls back:

```elixir
Repo.transact(fn ->
  promotion = Repo.one!(from p in Promotion, where: p.id == ^id, lock: "FOR UPDATE")

  with :ok <- pending(promotion),
       {:ok, approved} <- Repo.update(Promotion.approve(promotion, approver)) do
    {:ok, approved}
  end
end)
```

`Repo.rollback/1` is for leaving from deep inside the function; prefer `Ecto.Multi` for ordinary
atomic write sequences (`ehos-dev:elixir`, [data.md](../../elixir/references/data.md)).
Hard matches and bang functions remain useful for test setup and genuinely impossible internal
states. Do not replace handled validation/provider failures with assertions. A hard match on a
value that can hold a credential or the environment prints it when it fails: `ehos-dev:elixir`,
rule 4, "No error prints a value".

## Non-assertive truthiness

Only `false` and `nil` are falsy: `""`, `[]`, and `0` are truthy. Check empty environment strings
explicitly before declaring a required service key configured. Use `and`/`or` for boolean
contracts; `&&`/`||` are appropriate when intentionally handling optional values.

## Complex extractions in clauses and long parameter lists

Extract fields used solely by a body inside it when repeated head destructuring obscures dispatch.
Keep head patterns and guards that enforce a contract.
Group cohesive domain data in a typed struct when callers repeatedly swap adjacent arguments;
do not hide request scope in process state or introduce a struct for an isolated arity count.

## Namespace trespassing, comments overuse, and large structs

Avoid adding modules to a dependency's namespace: a library's modules live under its own root
(`EhosPlatform.*`, `EhOsContract.*`), and a package never defines one under another's. Contexts
have their own namespaces; check their boundaries before moving functions. Comments that explain
a non-obvious line and required `@doc`/`@moduledoc` are useful; stale or contradictory comments
are actionable. Do not split a schema or a struct because it reaches the upstream 32-field
threshold: demonstrate actual memory/copying cost or unrelated responsibilities before proposing a
change.
