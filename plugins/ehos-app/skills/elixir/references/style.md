# Style

What `mix format` and the `ehos-app:elixir-anti-patterns-review` skill do not already say. Where
a Credo check holds a rule, it is named here; whether it runs is the application's `.credo.exs`'s
to say. The rest a reviewer reads for.

## Control flow

- **No `case` or `with` inside another.** Move the inner one into a function of its own with a
  name that says what it decides, or into multi-clause heads. Credo's `Refactor.Nesting` catches
  only deeper nesting by default (more than two levels), so this one is read for.
- **A `with` without `else`** when each step returns its own `{:error, reason}` and the caller
  wants it as it is. An `else` that only re-wraps errors hides which step failed; one that
  matches many shapes means the steps should return one shape.
- **Multi-clause heads over `if` and `cond`** when the branches depend on the shape of an argument.
- **Bind the result of an `if` or `case`**; never rebind a variable inside its block expecting the
  change to leak out (it does not).

  ```elixir
  attrs = if confirmed?, do: Map.put(attrs, :confirmed_at, now), else: attrs
  ```

- **A key added only when its value is not `nil`** goes through `maybe_put/3`, private to the
  module that needs it and skipping `nil` alone, so a pipeline stays flat. Any other condition is
  an `if` at the call site, as above, where the reader sees it.

  ```elixir
  attrs |> maybe_put(:note, note) |> maybe_put(:due_on, due_on)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  ```

## Lists

- **No `acc ++ [item]` in a loop**: each append copies the list. Prepend and `Enum.reverse/1` at
  the end, or build with `Enum.map/2` or `Enum.flat_map/2`. Credo's opt-in
  `Refactor.AppendSingleItem` flags every `list ++ [item]`, in a loop or not.
- **No `length/1` to test a list's shape** (Credo's `Warning.ExpensiveEmptyEnumCheck` for the
  empty case): match on `[]`, `[_]`, `[_, _ | _]`, which is constant time and reads as the case it
  handles.

## Names

- **A predicate ends in `?` and never starts with `is_`** (Credo's
  `Readability.PredicateFunctionNames`): `paid?/1`. `is_` is for a guard, defined with
  `defguard`.

## Processes

- **Concurrent work over a collection** uses `Task.async_stream/3` with an explicit `timeout:`,
  `max_concurrency:` and `on_timeout: :kill_task`, handling `{:exit, :timeout}`, rather than
  `Task.async/1` per item: the default `on_timeout: :exit` takes the caller down with one slow
  item. The collection is bounded too (paged or chunked), and a call to an outside system for each
  item, from a request, belongs in an Oban job instead.
- **A `DynamicSupervisor` or `Registry` is named in its child spec** in the application's
  supervision tree, and reached by that name; never started from a function at runtime.

## Moduledocs and comments

A `@moduledoc` says what the module is and what it promises its callers. It may cite what a reader
can follow and that outlives the work: a platform decision (`eh-os D-112`), a contract's `source:`,
a document in `docs/`. It never cites a task id, a ticket number or a plan, nor tells the story of
how the module came to be: that is the commit's and the pull request's. A comment says why, where
the code cannot.
