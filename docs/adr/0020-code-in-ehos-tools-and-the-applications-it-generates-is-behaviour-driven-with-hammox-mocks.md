---
status: proposed
date: 2026-10-28
decision-makers: [Emil Wojtaszek]
consulted: [T-15, T-17]
---

# T-20 · Code in ehos-tools and in the applications it generates is behaviour-driven: a collaborator a test replaces is a behaviour with its implementation beside it, mocked with Hammox

## Context and problem statement

A senior Elixir review of an application `ehos_app` generated (EmpoweredHouse/ehos_taxvision, [pull
request 84](https://github.com/EmpoweredHouse/ehos_taxvision/pull/84) and
[85](https://github.com/EmpoweredHouse/ehos_taxvision/pull/85)) found too few behaviours: tests
swapped collaborators with `Application.put_env/3` and test hooks read from configuration, so they
could not run `async`, and nothing held a fake to the real module's types. The fix there, and the
template's half of it ([#504](https://github.com/EmpoweredHouse/ehos-tools/issues/504),
[#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506)), made **a way out of the
application** (an outside system, EHOS's APIs, mail, the clock, randomness) a behaviour mocked with
Hammox. A context could be one where a page's test should not run it, but the rule, and the
generated `docs/elixir.md`, named only the ways out.

This repository's own packages followed a third rule before this record
([CONTRIBUTING.md](../../CONTRIBUTING.md), then "Ways out are passed in"): a function in a command's
`opts` (`runner:` in `Ehosctl.Init`, `:now` in `Ehosctl.Notice`), or a behaviour mocked with Mox
for a library others call (`EhosPlatform.CommandRunner`). An audit of the packages on 28 October
2026 counted, in `ehosctl`'s `lib/` alone, two behaviours (`Ehosctl.Command`, `Ehosctl.TokenStore`)
against programs run from 8 files (`System.cmd`, `Port.open`), HTTP from 3 (`Req`, `:httpc`), the
clock read in 10 (`DateTime.utc_now`, `Date.utc_today`, `System.system_time`,
`System.monotonic_time`), the process environment in 17 (`System.get_env`), and more than a dozen
functions passed in `opts`. The functions in
`opts` carry no types, so a test's stand-in can drift from what it replaces, and each command
invents its own option for each collaborator.

The question is how far "behaviour-driven" goes: in the applications, every module whose callers'
tests should replace it, or only the ways out; in the packages, behaviours or functions in `opts`;
and how a library chooses its implementation, since its configuration belongs to whoever depends
on it (eh-os, for `ehos_platform`).

## Decision drivers

- A test replaces a collaborator per process, so it stays `async`, and the replacement is held to
  the real module's types.
- One rule a reader and an agent can apply without judgement calls, the same in the packages and in
  the applications where their situations are the same.
- A library works for its consumer with no configuration of the consumer's.
- No test hook in production code, and no `Application.put_env/3` in a test.

## Considered options

1. **Behaviour-driven everywhere, the implementation chosen by where the code runs.** A
   collaborator whose callers' tests should replace it is a behaviour, `X`, with `@callback`s and
   their `@doc`s, and its implementation `XImpl` in the same file; tests mock it with Hammox. An
   application or a release (`ehosctl`) chooses the implementation in its configuration, read by
   `X.current/0`; a library (`ehos_platform`, `ehos_app`, `ehos_design`) takes it as a module in
   the call's `opts`, defaulting to `XImpl`. In the applications this covers a context a page's
   test should not run, not only a way out.
2. **The same, with `current/0` from configuration in the libraries too**, each package gaining a
   `config/` directory, and a default to `XImpl` when the consumer sets nothing.
3. **Keep each place's rule**: ways out alone in the applications; functions in `opts` for
   commands and behaviours with Mox for libraries in the packages.

## Decision outcome

Chosen option: **"Behaviour-driven everywhere, the implementation chosen by where the code runs"**,
because it gives the packages and the applications one shape of module and one kind of mock, while
respecting that a library's configuration is its consumer's.

- **What gets a behaviour.** Every way out (a program, the network, the process environment, the
  keychain, the terminal, and the clock or randomness where a test must say what they return),
  and every module of the application's own whose
  callers' tests should not run it. Not a contract's part (it implements the behaviour its contract
  generates), not a pure module (a calculation, a parser, a formatter: test it directly), not an
  Oban worker (it calls its collaborators through theirs). The file system stays a parameter
  (`dir:`, `tmp_dir`): a test's own directory is real and fast, and a mocked `File` is brittle.
- **The shape.** `X` declares the `@callback`s, each with a `@doc` that says what it does, returns
  and how it fails, and `current/0` where configuration chooses; `XImpl` beside it is the real
  one. Callers name `X`, never `XImpl`. A mock is declared once, in `test/support/mocks.ex` (an
  application) or the test helper (a package), and `Hammox.Protect` holds `XImpl` to `X` in its
  own test.
- **Choosing the implementation.** An application: `config/config.exs` names `XImpl`,
  `config/test.exs` the mock, read with `Application.compile_env!/2` unless `config/runtime.exs`
  chooses (then at each call), as `docs/elixir.md` already says. `ehosctl`: at compile time
  alone, in a `config/` it gains, with no default in code, so a missing test line fails the build
  instead of reaching a real keychain from a test; nothing picks an implementation from the
  environment at run time. A library: a module in `opts[:x]`, named in its caller's code, never
  built from input, defaulting to `XImpl`, as `EhosPlatform.Server` chooses its runner today.
- **Commands keep their steps as data.** `Ehosctl.Command`'s split stays: a command builds its
  steps, then runs them; what runs a step is the behaviour.

### Consequences

- Good, because every stand-in is checked against the real module's types, and a test that swaps
  a collaborator stays `async`.
- Good, because the packages and the applications read alike; an agent working in either applies
  one rule, and `ehos-dev:elixir` and `ehos-app:elixir` teach the same shape.
- Bad, because there are more modules and files: a behaviour, its implementation, a mock line and
  a config line for each collaborator. Mitigated: the pair lives in one file, and a pure module
  needs none.
- Bad, because `ehosctl`'s existing functions in `opts` (more than a dozen), `ehos_platform`'s
  (three) and its Mox mock are now old code. They move to this shape area by area, each in a pull
  request of its own; code a change does not touch is not a finding until then.
- Bad, because a library's call sites name the implementation in `opts` rather than configuration,
  a second way to choose one. Mitigated: it is the library case alone, and the default makes it
  invisible to a consumer.
- Neutral: Hammox becomes a test dependency of the packages that mock, in place of Mox.

### Confirmation

- [CONTRIBUTING.md](../../CONTRIBUTING.md), "Code" and "Tests", states the rule, and
  `.claude/review.md` names it for a reviewer.
- To change, as the audit's next steps: the template's half (the generated `docs/elixir.md` and the
  `ehos-app:elixir` skill, which today name only the ways out), with the installer's tests asserting
  the generated sections; and `ehos-dev:elixir`, a skill that teaches this rule in ehos-tools.
- To write: a test in each package that fails when a module that is not a behaviour's
  implementation runs a program, reads the clock or the environment, or calls HTTP directly
  (`System.cmd/3`, `Port.open/2`, `DateTime.utc_now/0`, `System.get_env/0,1`, `Req`), with the
  modules written before the rule listed until they move, as `test/conventions_test.exs` does for
  `Ecto.Query` in an application; and `mix test --warnings-as-errors` in `mix check`.

## Pros and cons of the options

### Behaviour-driven everywhere, the implementation chosen by where the code runs

- Good, because one shape of module and mock across packages and applications.
- Good, because a library needs nothing from its consumer's configuration.
- Bad, because two ways to choose an implementation exist, by where the code runs.

### The same, with `current/0` from configuration in the libraries too

- Good, because one way to choose an implementation everywhere.
- Bad, because a library would read keys from its consumer's configuration, and a default to
  `XImpl` hides a missing test line rather than failing, the opposite of what the applications'
  rule wants.
- Bad, because a test that wants a different implementation for one call has to change global
  configuration.

### Keep each place's rule

- Good, because nothing moves.
- Bad, because a function in `opts` carries no types, and the applications' contexts stay
  unmockable at the level a page calls them, which the review found.
- Bad, because an agent learns three rules for one question.

## More information

Decided under [#506](https://github.com/EmpoweredHouse/ehos-tools/issues/506), in the Elixir
standards audit of 28 October 2026 that followed it and
[#504](https://github.com/EmpoweredHouse/ehos-tools/issues/504).

Revisit if Hammox stops being maintained, or if Elixir's type system checks a stand-in against a
behaviour on its own.
