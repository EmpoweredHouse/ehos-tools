defmodule Ehosctl.Case do
  @moduledoc """
  `ExUnit.Case` with the mocks of ehosctl's ways out (T-20) imported and verified on exit. Each
  test starts with an empty environment (`Ehosctl.SystemEnv`), which one that needs a variable
  gives with `stub_env/1`; this machine's answers to `Ehosctl.OS` and its real `Ehosctl.Clock`,
  which one that must say them stubs or expects; no terminal with nothing typed
  (`Ehosctl.Terminal`); and `Ehosctl.FakeKeychain` as the system's keychain
  (`Ehosctl.SystemKeychain`). `Ehosctl.Runner` and `Ehosctl.Browser` have no default: a test that
  runs a program or opens a page says so. `ehosctl/2` runs a command line and returns its exit
  code, stdout and stderr; a test that is not async gets it.
  """

  use ExUnit.CaseTemplate

  using opts do
    helpers = [
      change_config_while_locked: 2,
      stub_browser: 1,
      stub_env: 1,
      stub_home: 1,
      stub_now: 1,
      stub_virtual_clock: 0
    ]

    helpers = if opts[:async], do: helpers, else: [{:ehosctl, 2} | helpers]

    quote do
      import Hammox

      import Ehosctl.Case, only: unquote(helpers)

      setup :verify_on_exit!
    end
  end

  setup do
    Hammox.stub_with(Ehosctl.OSMock, Ehosctl.OSImpl)
    Hammox.stub_with(Ehosctl.ClockMock, Ehosctl.ClockImpl)
    Hammox.stub(Ehosctl.TerminalMock, :gets, fn _prompt -> nil end)
    Hammox.stub(Ehosctl.TerminalMock, :read_input, fn _count -> :eof end)
    Hammox.stub(Ehosctl.TerminalMock, :input_terminal?, fn -> false end)
    Hammox.stub(Ehosctl.TerminalMock, :error_terminal?, fn -> false end)
    Hammox.stub(Ehosctl.SystemKeychainMock, :backend, fn -> Ehosctl.FakeKeychain end)
    stub_env(%{})
  end

  @doc "Makes `browse`, a function of the URL, the browser `Ehosctl.Browser` opens a page in."
  @spec stub_browser((String.t() -> term())) :: :ok
  def stub_browser(browse) do
    Hammox.stub(Ehosctl.BrowserMock, :open, fn url, _opts ->
      browse.(url)
      :ok
    end)

    :ok
  end

  @doc """
  Makes `Ehosctl.Clock` a clock whose waits take no time: its monotonic time starts at 0, and the
  time of day at the real one's whole second, and both move on only by what it is told to sleep,
  so a wait of ten minutes is read at once, and passes.
  """
  @spec stub_virtual_clock() :: :ok
  def stub_virtual_clock do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    started = DateTime.truncate(DateTime.utc_now(), :second)
    Hammox.stub(Ehosctl.ClockMock, :monotonic, fn -> Agent.get(clock, & &1) end)

    Hammox.stub(Ehosctl.ClockMock, :now, fn ->
      DateTime.add(started, Agent.get(clock, & &1), :millisecond)
    end)

    Hammox.stub(Ehosctl.ClockMock, :sleep, fn ms -> Agent.update(clock, &(&1 + ms)) end)
    :ok
  end

  @doc """
  Holds `config.json.lock` in `dir` in another process until a command waits for it, then
  writes the configuration `change` returns, as another command at the same moment would, and
  lets the lock go. Returns that process, for `Task.await/1` after the command.

  The wait is seen as the command's first `Ehosctl.Clock` sleep, which this stubs for the rest of
  the test: a command that sleeps before it waits for the lock is not one to test with it.
  """
  @spec change_config_while_locked(Path.t(), (-> Ehosctl.Config.t())) :: Task.t()
  def change_config_while_locked(dir, change) do
    test = self()
    File.mkdir_p!(dir)

    holder =
      Task.async(fn ->
        Ehosctl.FileLock.with_lock(Ehosctl.Config.path(dir) <> ".lock", "the test holds it", fn ->
          send(test, :locked)

          receive do
            :waiting -> Ehosctl.Config.write(change.(), dir)
          end
        end)
      end)

    Hammox.stub(Ehosctl.ClockMock, :sleep, fn ms ->
      send(holder.pid, :waiting)
      Process.sleep(ms)
    end)

    receive do
      :locked -> holder
    after
      5_000 -> raise "the test could not take #{Ehosctl.Config.path(dir)}.lock"
    end
  end

  @doc "Makes `home` the user's home directory, as `Ehosctl.OS` gives it."
  @spec stub_home(Path.t()) :: :ok
  def stub_home(home) do
    Hammox.stub(Ehosctl.OSMock, :home, fn -> home end)
    :ok
  end

  @doc "Makes the environment `env`, a map of names to values, for this test's processes."
  @spec stub_env(%{String.t() => String.t()}) :: :ok
  def stub_env(env) do
    Hammox.stub(Ehosctl.SystemEnvMock, :all, fn -> env end)
    Hammox.stub(Ehosctl.SystemEnvMock, :get, &Map.get(env, &1))
    :ok
  end

  @doc "Makes `now` the time of day `Ehosctl.Clock` gives."
  @spec stub_now(DateTime.t()) :: :ok
  def stub_now(now) do
    Hammox.stub(Ehosctl.ClockMock, :now, fn -> now end)
    :ok
  end

  @doc """
  Runs `argv` with `opts`, returning `{exit code, stdout, stderr}`. It captures stderr, which is
  one device for every process, so only a test that is not async imports it.
  """
  @spec ehosctl([String.t()], keyword()) :: {non_neg_integer(), String.t(), String.t()}
  def ehosctl(argv, opts) do
    {{code, stdout}, stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        ExUnit.CaptureIO.with_io(fn -> Ehosctl.CLI.main(argv, opts) end)
      end)

    {code, stdout, stderr}
  end
end
