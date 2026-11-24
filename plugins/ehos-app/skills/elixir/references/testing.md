# Tests

`TESTING.md` says how the suite runs, how a contract is tested, and which behaviours this
application mocks. This is how a test is written.

## Mocks with Hammox

Hammox is Mox that also checks each call and answer against the behaviour's `@callback` types, so
a mock cannot drift from the implementation it stands for.

- **Declared once**, in `test/support/mocks.ex`: `Hammox.defmock(Shop.DirectoryMock, for:
  Shop.Directory)`. **Named once**, in `config/test.exs` ([behaviours.md](behaviours.md)). Never
  swapped in a test with `Application.put_env/3`.
- **Set up by the case**: `DataCase` and `ConnCase` call `setup_mocks/1`, which picks Mox's mode
  from the test (`set_mox_from_context`: private in an `async` test, global in one that is not),
  verifies expectations on exit, and stubs each mock with a default where the application has
  one (`stub_with(Shop.ClockMock, Shop.ClockImpl)`). A default never grants access: a way out
  that answers who may do what is stubbed to refuse, or not stubbed at all.
- **Other processes**: in a private test, a mock reaches the test's own process and the processes
  it starts (a `Task`, a LiveView under `Phoenix.LiveViewTest`, and, with Mox 1.3 or later, a
  process under `start_supervised/1`). A process the test did not start, such as one already in
  the application's supervision tree, needs `allow(Shop.DirectoryMock, self(), pid)`; a test
  where that is impractical is the non-async one, in global mode.
- **`expect/4` for a call the test is about**, with the arguments it must receive matched in the
  function head. `expect(mock, :fun, 0, fn ... end)` says a call must not happen.
- **In helpers at the bottom of the file**, `mock_<function>/1` or `mock_<function>/2`, one per
  way the test file needs the call to answer, so each test reads as its scenario:

  ```elixir
  test "a task whose assignee left EHOS shows no name", %{task: task} do
    mock_person({:error, :not_found})

    assert Shop.Tasks.assignee_name(task) == {:ok, nil}
  end

  defp mock_person(answer),
    do: expect(Shop.DirectoryMock, :person, fn "person-1" -> answer end)
  ```

- **`Hammox.Protect`** in the implementation's own test holds it to the behaviour:
  `use Hammox.Protect, module: Shop.DirectoryImpl, behaviour: Shop.Directory`, and the test calls
  the protected functions.

## Mock what the caller calls

A test replaces what the code under test calls, at that level, and nothing beneath it. A test
that mocks two levels down is testing the wiring between them, and breaks whenever it changes.

- **A context's test** mocks its ways out, and runs its tables in the sandbox.
- **A page's or controller's test** runs the real context against the sandbox, as the template's
  own tests do. Where it should not (the context reaches a way out the page's test should not
  care about), it mocks the context function the page calls, which makes that context a behaviour
  ([behaviours.md](behaviours.md)); never the repo, the HTTP client or the other contexts that
  function uses.
- **Never mocked:** the router's pipelines, `on_mount` and `EhosContract.Auth`. A page's test
  goes through the real sign-in, keeps a case for a visitor who is not signed in, and a context
  function a page calls takes the actor, so that the context's own test covers its refusal.

## Data from factories

- **A factory for every struct more than one test builds**, error structs included, in
  `test/support/factories.ex` with ExMachina. A test changes only the fields its scenario is
  about: `insert(:order, total: 0)`.
- **No literal for what the factory gave.** A test reads a value the factory chose from what it
  built, and names a value as a literal only where it overrides it, so changing the factory
  breaks no test that does not care:

  ```elixir
  order = insert(:order, total: 0)

  assert Shop.Orders.unpaid(order.customer_id) == [order]
  # Not: assert Shop.Orders.unpaid("customer-1") == [order], repeating the factory's default
  ```
- **Imported, not aliased**: `import Shop.Factories` in the case, so a test reads `build(:order)`.
- **No hand-rolled builders** (`sample_order/1`, `valid_attrs/0`) in a test file: they are a second
  factory module, kept by no one.
- An event or a command of a contract is built from the contract's own structs, as its scenarios
  are: a factory for it is fine, a map shaped like it is not.

## What a test says

- **Its name is the scenario**, in the application's words: "a task whose assignee left
  EHOS shows no name", not "assignee_name/1 returns nil". It never names the implementation
  (`impl`, `DirectoryImpl`), and the test module is named after the behaviour,
  `Shop.DirectoryTest`.
- **The happy path first** in a `describe`, then the ways it fails, so a reader sees what the
  function is for before what it refuses.
- **Private helpers at the bottom of the file**: `defp` and the `mock_*` helpers come after every
  test, so the file reads from the top as its scenarios.
- **Compare the whole answer with `==`**, so a field added or changed by mistake fails the test.
  Match a part only where the rest cannot be known (a generated id), and then pin what can.
- **Not a restatement of the output.** A test that lists the paths a router declares, or asserts a
  regex another test already holds, fails on every change and catches nothing.
- **One behaviour per test.** Setup that several tests share goes in `setup`, named by what it
  makes.

## `async`

`async: true` unless the test dispatches a contract's command (every append to the engine's log
takes one lock, held for the sandbox's transaction) or shares a mock with processes it does not
start itself. A test is never made non-async to change application configuration: that is the
`put_env` it should not do.
