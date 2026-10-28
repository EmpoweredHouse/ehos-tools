# Style

What `mix format` does not already say.

## Control flow

- **No `case` or `with` inside another.** Move the inner one into a function named for what it
  decides, or into multi-clause heads.

  ```elixir
  # Not this
  case fetch(id) do
    {:ok, item} ->
      case authorize(item, actor) do
        :ok -> {:ok, item}
        error -> error
      end

    error ->
      error
  end

  # This: the inner decision gets a name
  case fetch(id) do
    {:ok, item} -> authorized(item, actor)
    error -> error
  end

  defp authorized(item, actor) do
    case authorize(item, actor) do
      :ok -> {:ok, item}
      error -> error
    end
  end
  ```

  Where every step answers `{:ok, _}` or `{:error, _}`, a `with` without `else` says the same
  in one place.

- **A `with` without `else`** when each step returns its own `{:error, reason}` and the caller
  wants it as it is. An `else` that only re-wraps errors hides which step failed.
- **Multi-clause heads over `if` and `cond`** when the branches depend on an argument's shape:
  `[]` against `[_ | _]`, `nil` against a value.
- **Bind the result of an `if` or `case`**; never rebind a variable inside its block expecting the
  change to leak out (it does not).
- **A key set only when its value is not `nil`** goes through `maybe_put/3`, private to the module
  and skipping `nil` alone, so a pipeline stays flat. Any other condition is an `if` at the call
  site, where the reader sees it.

  ```elixir
  body |> maybe_put("ca", ca) |> maybe_put("note", note)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  ```

## Lists and names

- **No `acc ++ [item]` in a loop**: prepend and reverse, or build with `Enum.map/2`.
- **No `length/1` to test a list's shape**: match on `[]`, `[_]`, `[_, _ | _]`.
- **A predicate ends in `?`** and never starts with `is_`, which is for a guard.
- **No `String.to_atom/1` on anything from outside**; map it to a fixed set of atoms instead.

## Docs and comments

- **Every public module has a `@moduledoc`**, every public function a `@doc` and a `@spec`, every
  `@callback` a `@doc`: what it does for its caller, what it returns and how it fails, with an
  example where one helps. An internal module says `@moduledoc false` on purpose.
- **A moduledoc says what the module is.** It may cite what outlives the work and a reader can
  follow: an issue with its repository (`ehos-tools#505`), a decision record (`T-20`,
  `eh-os D-92`). Never a plan's language ("phase 2", "for now").
- **A comment says why**, where the code cannot, and names the limitation it works around so the
  next reader can check it still holds.
- **No section comments** (`# --- Helpers ---`): a module that needs sections is too big, or its
  private functions should read top-down. **No dead code**: a function whose last caller goes,
  goes with it.

## Warnings

A warning is a failure: compile with `--warnings-as-errors`. Where the repository's gate runs
`mix test --warnings-as-errors`, which also fails on a warning in a test file, a test leaves none
either; in ehos-tools that is planned (T-20, "Confirmation").
