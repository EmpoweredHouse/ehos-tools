# Style

What `mix format` and the `ehos-app:elixir-anti-patterns-review` skill do not already say. A rule
Credo can check is a check in the template's `.credo.exs`, named here; the rest a reviewer reads
for.

## Control flow

- **No `case` or `with` inside another** (Credo's `Refactor.Nesting`). Move the inner one into a
  function of its own with a name that says what it decides, or into multi-clause heads.
- **A `with` without `else`** when each step returns its own `{:error, reason}` and the caller
  wants it as it is. An `else` that only re-wraps errors hides which step failed; one that
  matches many shapes means the steps should return one shape.
- **Multi-clause heads over `if` and `cond`** when the branches depend on the shape of an argument.
- **Bind the result of an `if` or `case`**; never rebind a variable inside its block expecting the
  change to leak out (it does not).

  ```elixir
  attrs = if note, do: Map.put(attrs, :note, note), else: attrs
  ```

  This also replaces `maybe_put/3`-style helpers, which hide the condition at the call site.

## Lists

- **No `acc ++ [item]` in a loop**: each append copies the list (Credo's
  `Refactor.AppendSingleItem`). Prepend and `Enum.reverse/1` at the end, or build with
  `Enum.map/2` or `Enum.flat_map/2`.
- **No `length/1` to test a list's shape** (Credo's `Warning.ExpensiveEmptyEnumCheck` for the
  empty case): match on `[]`, `[_]`, `[_, _ | _]`, which is constant time and reads as the case it
  handles.

## Names

- **A predicate ends in `?` and never starts with `is_`** (Credo's
  `Readability.PredicateFunctionNames`): `paid?/1`. `is_` is for a guard, defined with
  `defguard`.

## Processes

- **Concurrent work over a collection** uses `Task.async_stream/3` with an explicit `timeout:` and
  `max_concurrency:`, so it has back-pressure and a bound, rather than `Task.async/1` per item.
- **A `DynamicSupervisor` or `Registry` is named in its child spec** in the application's
  supervision tree, and reached by that name; never started from a function at runtime.

## Moduledocs and comments

A `@moduledoc` says what the module is and what it promises its callers. It may cite what a reader
can follow and that outlives the work: a platform decision (`eh-os D-112`), a contract's `source:`,
a document in `docs/`. It never cites a task id, a ticket number or a plan, nor tells the story of
how the module came to be: that is the commit's and the pull request's. A comment says why, where
the code cannot.
