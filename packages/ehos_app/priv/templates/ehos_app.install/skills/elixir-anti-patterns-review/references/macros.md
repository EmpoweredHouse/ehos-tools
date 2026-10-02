<!--
  SPDX-License-Identifier: Apache-2.0
  SPDX-FileCopyrightText: 2021 The Elixir Team
  Modified: condensed and adapted for the Shugyo backend.
-->

# Macro patterns

## Unnecessary macros and `use` instead of `import`

For custom macros, ask what needs AST manipulation, caller context, or compile-time generation.
Use a function when it achieves the same behavior. A `__using__/1` that only imports helpers may
be replaceable by an explicit import; don't make that change when it also installs callbacks,
attributes, or generated definitions.

Phoenix, Ecto query/schema DSLs, `TypedEctoSchema`, `TypedStruct`, ExUnit case templates, and
`use GenServer` are deliberate framework mechanisms. Their presence is not a finding.

## Large code generation

Check whether a custom macro emits repeated validation or business logic into every caller.
Move ordinary work into functions and leave the necessary AST wiring in the macro. Establish
expansion size or compilation cost before claiming a performance defect; a large router alone
does not justify replacing Phoenix's DSL.

## Compile-time dependencies

Distinguish required compile-time access to structs/module metadata from aliases used only by
generated runtime calls. For a suspected recompilation cascade, inspect from `apps/backend`:

```bash
mix xref trace apps/api/lib/api/<actual-file>.ex
```

Substitute the actual file. Run this only when the compile graph matters to the finding, and never
concurrently with another `mix` command. Literal expansion in caller function context can reduce
false compile dependencies, but is appropriate only if the macro never needs that module at
compile time. Preserve runtime-configured behaviour lookups used by service-client tests.

## Untracked compile-time dependencies

Building aliases with string concatenation, `Module.concat`, or raw module atoms can hide a real
compile-time dependency. Prefer explicit aliases when the target set is fixed, and use compiler
tracing to verify that a change to the target rebuilds the caller. Dynamic dispatch at runtime is
not the same problem; don't rewrite configured behaviour modules into compile-time dependencies.
