# Behaviours

A collaborator a test replaces is a behaviour, so the test replaces it per process with a Hammox
mock, and the `@callback`s are the one description of what the code expects from it.

## What gets one

- **Every way out**: a program (`System.cmd/3`, a `Port`), the network, the process environment,
  the keychain, the terminal (a prompt, a browser opened), and the clock or randomness where a
  test must say what they return. Where no test cares what time it is, read the clock directly.
- **A module whose callers' tests should not run it**: a command's runner, say, which every
  command's test replaces to read the steps it would run.
- **Not**: a pure module (a parser, a formatter, a calculation), tested directly; and a path,
  which stays a parameter (`dir:`, a test's `tmp_dir`), since a test's own directory is real and
  fast, and a mocked `File` is brittle.
- **Not a function the caller gives**: one through which a library tells its caller what is
  happening (a `:progress` callback) is the caller's, and stays a function in `opts`.

## The shape

The examples are illustrations, with names a CLI might use; check what the repository has before
calling a module by name. The behaviour and its implementation in one file. Callers name the
behaviour, never the implementation.

```elixir
defmodule Ehosctl.Clock do
  @moduledoc "The time, as a way out, so that a test can say what time it is."

  @doc "Now, in UTC."
  @callback now() :: DateTime.t()

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Ehosctl.ClockImpl do
  @moduledoc false
  @behaviour Ehosctl.Clock

  @impl true
  def now, do: DateTime.utc_now()
end
```

A caller reads `Ehosctl.Clock.current().now()`.

## Choosing the implementation

**A CLI, such as `ehosctl`, chooses at compile time**, between the real implementation and the
mock. `current/0` reads `Application.compile_env!/2`, with no default in code, and only the
environment-specific files name one:

```elixir
# config/dev.exs and config/prod.exs
config :ehosctl, Ehosctl.Clock, impl: Ehosctl.ClockImpl

# config/test.exs
config :ehosctl, Ehosctl.Clock, impl: Ehosctl.ClockMock
```

A behaviour whose test line is missing then fails to compile, rather than reaching a real
keychain or installation from a test. Nothing in `config/config.exs` names one: a shared default
would hide the missing line.

**The real implementation may still choose among real backends at run time**: a token store that
uses the keychain on macOS, the Secret Service where it exists and a file elsewhere, or a
credential source chosen by an environment variable. It reads the OS and the environment through
their own behaviours, so its test can say what they return. A variable's value is matched against
a fixed set of literal values, each naming its module in code, and anything else is an error:
never a module built from the value, never a silent fallback.

A Phoenix application, such as EHOS itself, names the real implementation in `config/config.exs`
and the mock in `config/test.exs`, and may choose at run time in `config/runtime.exs`, as the
repository's own rules say.

**A library chooses in `opts`**, since its configuration is its consumer's. The module is named in
its caller's code, never built from input, a string or the environment:

```elixir
@doc "Applies the plan in `dir`; `:runner` replaces the program runner, for a test."
@spec apply_plan(Path.t(), keyword()) :: :ok | {:error, String.t()}
def apply_plan(dir, opts \\ []) do
  runner = Keyword.get(opts, :runner, Tools.RunnerImpl)

  case runner.run("tofu", ["-chdir=" <> dir, "apply", "-auto-approve"]) do
    {_output, 0} -> :ok
    {_output, status} -> {:error, "tofu apply exited with #{status}"}
  end
end
```

A program runs from its executable and a list of arguments, never a shell string (`sh -c`,
`:os.cmd/1`), so no argument is read as shell syntax.

## No test hook in production code

Production code never reads, for a test's sake, a canned answer, a process to notify, a delay or a
flag from configuration. Each is a second implementation hidden in the first, and a test that sets
it changes global state, so it cannot be `async`. Make what it stands for a behaviour, and have
the test `expect` the call instead.

## Options

An option that stays in `opts` (a library's implementation, data such as an installation or a CA)
is followed to every call it must reach. A `Keyword.take/2` on the way drops it, and the call
falls back to the real program or environment without a word.

## No error prints a value

What a CLI prints of an error, a CI job's log keeps. An exception that carries a term can carry a
credential or the environment: a `KeyError` over `opts` holds the whole list, a `MatchError` the
value that did not match, an `ErlangError` or an `ArgumentError` its argument. So:

- keep the environment and credentials out of `opts` that a `fetch!` could print; read the keys you
  need through the environment's behaviour, and pass a credential to the request that sends it;
- never match a credential with `=` where a failure would raise; match it in a `case` or a
  function head with a last clause that answers an error naming what failed, not its value, since
  a `CaseClauseError` or a `FunctionClauseError` holds the value too;
- build an `{:error, message}`, and the message of anything raised, from what failed, never from
  `inspect/1` of a term that can hold a credential;
- where the repository prints only the messages of exceptions known to hold no value (in
  ehos-tools, `Ehosctl.Application.shown/1`, which `run/2` calls), a new exception that holds none
  is added there, and nothing prints an error around it.
