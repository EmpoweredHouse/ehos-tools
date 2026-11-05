# Structure

How the code of a repository is divided and started: contexts and their boundaries, what the web
layer may call, which OTP application holds what, and how a supervised process and a setting get
their values. A library or a CLI has fewer of these parts than a Phoenix platform; read the
sections that match what you write.

The repository's own rules win where they differ: eh-os keeps them in `CONTRIBUTING.md`, "Code",
and its decision records (one OTP application in one image, D-26; the developer tools outside the
production build, D-159; collaborators and settings as behaviours, D-160). ehos-tools keeps its
own in its `CONTRIBUTING.md` and T-20. The examples are illustrations; check what the repository
has before calling a module by name.

## A context is a boundary

A context is the code's own API for one area: deployments, promotions, environments. Its root
module holds the functions its callers use; its other modules are its own.

- **Each context declares its boundary** with the [`boundary`](https://hexdocs.pm/boundary)
  library, where the repository has it: `deps:` the contexts and shared modules it calls,
  `exports:` the modules its callers may name (a schema it hands out, a struct of its answers).
  A call into another context's inner module is then a compiler warning, which rule 8 makes a
  failure.

  ```elixir
  defmodule Ehos.Promotions do
    @moduledoc "Moves a version of an application from a candidate to production."
    use Boundary, deps: [Ehos.Repo, Ehos.Deployments, Ehos.Audit], exports: [Promotion]
  end
  ```

- **Two contexts that need each other** are one context, or share a third that both call. A cycle
  that `deps:` cannot express is a design question, not a list to extend.
- **A context composes its ways out and its tables**, and normalises input once, at its boundary.
  Its public functions each have a `@spec`, and answer as [data.md](data.md), "What a context
  answers", says.
- **A module past a reader's span** (a thousand lines, or functions that serve two kinds of
  caller) splits along the seams its callers show: the decision, the cluster's side, the queries.
  The parts stay inside the context's boundary.

## The web layer calls contexts

A controller, a LiveView or a plug reads the request, makes one call to a context, and renders
what comes back.

- **No `Repo` and no `Ecto.Query` in the web layer.** A page that needs rows asks the context
  that owns them. The web's boundary `deps:` the contexts, never the repo.
- **A call that stitches two contexts together** (read one, decide, write another) is a context
  function. The page calls it once.
- **What goes over the wire is shaped by the `*HTML` or `*JSON` module**, never the controller:
  field names, a date as ISO 8601, a URL built from a route.
- **A refusal is mapped to its words in one place** per surface: a controller's fallback, a
  LiveView's function for refusals.

## OTP applications

An OTP application is a unit that starts, stops and is released together. Split code into one
when it has a different lifecycle or a different audience, not to draw a line a boundary already
draws.

- **The product is one application** unless the repository decided otherwise. Contexts and
  `boundary` separate its areas.
- **Code that only a developer or CI runs is a Mix project of its own**, taken as a path
  dependency `only: [:dev, :test]`, so a production build does not contain it, and its Mix tasks
  still run from the root (eh-os's `tools/ehos_dev`, D-159).
- **A library has an application callback** (`mod:` in its `mix.exs`) only where it supervises
  processes. A library of functions has none.

## Supervision

A process exists to own state, a resource or concurrency: a connection, a cache, a schedule, a
queue. A module of pure functions is not a process.

- **The children are a pure function of the settings**, such as `Ehos.Application.children/1`,
  which `start/2` calls with what the configuration says. A test calls it with production
  settings and holds which processes start; nothing inside a process checks an `enabled:` flag.
- **Order follows need**: the repo before what queries it, the endpoint last, so a request never
  reaches a process that has not started.
- **Background work runs under a supervisor**: a `Task.Supervisor` for a task whose failure the
  caller handles (`async_nolink/3`), never a bare `spawn/1` or a linked `Task.async/1` there.

## A supervised process takes its values when it starts

A Hammox expectation reaches the test's own process, those that carry it in `$callers` (a
`Task`), those whose parents lead to it (a process under the test's `start_supervised!/1`, with
Mox 1.3 or later, which Hammox wraps), and those it names with `allow/3`. A process the
application starts is none of these, so a test cannot set what it reads. A supervised process
therefore takes, as start options:

- **its settings** (an interval, a limit, a timeout),
- **its collaborators** (each a behaviour's module: the clock, the cluster, an HTTP client),
- **its name**,

each defaulting to its production value. A test starts its own instance beside the
application's, unnamed or with a name of its own, and sets what the mock answers before it
starts:

```elixir
# The process
@spec start_link(keyword()) :: GenServer.on_start()
def start_link(opts) do
  {name, opts} = Keyword.pop(opts, :name, __MODULE__)
  GenServer.start_link(__MODULE__, opts, name: name)
end

@impl GenServer
def init(opts) do
  state = %{
    clock: Keyword.get(opts, :clock, Ehos.Clock.current()),
    every: Keyword.get(opts, :every, :timer.minutes(1))
  }

  {:ok, state, {:continue, :schedule}}
end

# Its test: the instance is the test's child, so the mock reaches it through its parent
expect(Ehos.ClockMock, :now, fn -> ~U[2026-11-05 12:00:00Z] end)
start_supervised!({Ehos.Expirer, name: nil, clock: Ehos.ClockMock, every: :timer.hours(1)})
```

- **What the first call needs is set before the start**: an `expect/4` or `stub/3` made after
  `start_supervised!/1` can come after `handle_continue/2` has called the mock.
- **Work that needs a collaborator goes in `handle_continue/2`**, not `init/1`, so a failure of
  the collaborator is a restart of the process, not a failed start of its supervisor.
- **`allow/3` is for a process the test did not start**, or one started in `setup_all`, whose
  parent is not the test's process.
- **A test that counts calls sets a long interval**, or drives each tick with a message it sends,
  so a second tick does not call the mock again while the test runs.
- **A test that needs the application's own instance** stays `async: false`, and says why in its
  module.

## Settings

A setting is a value the configuration gives: a URL, a limit, whether four eyes approve a
promotion. Each kind of code reads them its own way.

- **A Phoenix application** reads them in `config/runtime.exs` from the environment, through one
  function per area (`from_env!/1`, or one it calls) that validates each value and holds its
  default. A wrong value stops the node at boot, with what is wrong and never the value itself.
  Code that reads the setting later fetches it with no default of its own
  (`Application.fetch_env!/2`, `Keyword.fetch!/2`), so the defaults live in that one function, and
  its own test holds each of them.
- **A setting a test varies** is read through a behaviour of the context that owns it, with
  `X.current/0` and `XImpl` as [behaviours.md](behaviours.md) says, and the test `expect`s the
  value (eh-os, D-160). A setting that every test reads at one value stays in `config/test.exs`.
- **A value that only a test changes** is not a setting: a test hook. It goes, as rule 4 says,
  and the code takes a constant, a start option or a behaviour instead.
- **A CLI** chooses at compile time ([behaviours.md](behaviours.md), "Choosing the
  implementation").
- **A library** takes its settings in `opts`, never from `Application` env, since its
  configuration is its consumer's. It validates them where they enter, with
  [`NimbleOptions`](https://hexdocs.pm/nimble_options) where it has many, and says the defaults in
  the function's `@doc`.
