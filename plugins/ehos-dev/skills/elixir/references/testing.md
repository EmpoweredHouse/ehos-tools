# Tests

## Mocks with Hammox

Hammox is Mox that also checks each call and answer against the behaviour's `@callback` types, so
a mock cannot drift from the implementation it stands for.

- **Test-only.** `{:hammox, "~> 1.0", only: :test}`, and every mock declared in the test helper or
  `test/support/`, never under `lib/`, so a release cannot hold one:
  `Hammox.defmock(Ehosctl.ClockMock, for: Ehosctl.Clock)`.
- **`expect/4` for the call a test is about**, with the arguments it must receive matched in the
  function head; `stub/3` only for a call it does not count. `expect(mock, :fun, 0, fn ... end)`
  says a call must not happen. Verify on exit (`setup :verify_on_exit!`).
- **In helpers at the bottom of the file**, `mock_<function>`, one per way the file needs the call
  to answer, so each test reads as its scenario:

  ```elixir
  test "a sign-in issued three hours ago says so" do
    mock_now(~U[2026-10-28 12:00:00Z])

    assert Ehosctl.Credentials.age(credential(issued_at: ~U[2026-10-28 09:00:00Z])) ==
             "3 hours ago"
  end

  defp mock_now(now), do: expect(Ehosctl.ClockMock, :now, fn -> now end)
  ```

- **`Hammox.Protect`** holds an implementation to its behaviour in its own test, where that test
  reaches no real resource. An implementation that runs a program or calls the network is tested
  through the runner or HTTP behaviour it calls, mocked in turn.
- **Fixture credentials only.** Hammox's errors print the arguments, and a CI log keeps them.
- **Never swapped through the environment.** A test does not change `Application` env or the
  process environment to choose an implementation; configuration a library reads the same way in
  every test is not such a swap.

## What a test says

- **Its name is the scenario**: what the code does, in the words of its user, never how it does
  it. A test module is named after the module it tests, never `*Impl`, and no test name says
  "impl".
- **Compare the whole answer with `==`**, so a field changed by mistake fails the test. Match a
  part only where the rest cannot be known, and pin what can.
- **Success first** in each `describe`, then the failures. Helpers at the bottom of the file.
- **Not a restatement of the output**: a test that lists what another test already holds catches
  nothing.
- **It fails when what it guards is removed.** Undo the fix, run the test, see it red.

## `async`

`async: true` unless the test shares a process it does not start. A test is never made non-async
to change configuration: that is the swap it should not do.
