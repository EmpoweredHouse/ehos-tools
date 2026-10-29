defmodule Ehosctl.Case do
  @moduledoc """
  `ExUnit.Case` with the mocks of ehosctl's ways out (T-20) imported and verified on exit. Each
  test starts with an empty environment (`Ehosctl.SystemEnv`), which one that needs a variable
  gives with `stub_env/1`; this machine's answers to `Ehosctl.OS` and its real `Ehosctl.Clock`,
  which one that must say them stubs or expects; and no terminal with nothing typed
  (`Ehosctl.Terminal`). `Ehosctl.Runner` and `Ehosctl.Browser` have no default: a test that runs a
  program or opens a page says so.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Hammox
      import Ehosctl.Case, only: [stub_browser: 1, stub_env: 1, stub_virtual_clock: 0]

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
  Makes `Ehosctl.Clock` a clock whose waits take no time: its monotonic time starts at 0 and moves
  on only by what it is told to sleep, so a wait of ten minutes is read at once, and passes.
  """
  @spec stub_virtual_clock() :: :ok
  def stub_virtual_clock do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    Hammox.stub(Ehosctl.ClockMock, :monotonic, fn -> Agent.get(clock, & &1) end)
    Hammox.stub(Ehosctl.ClockMock, :sleep, fn ms -> Agent.update(clock, &(&1 + ms)) end)
    :ok
  end

  @doc "Makes the environment `env`, a map of names to values, for this test's processes."
  @spec stub_env(%{String.t() => String.t()}) :: :ok
  def stub_env(env) do
    Hammox.stub(Ehosctl.SystemEnvMock, :all, fn -> env end)
    Hammox.stub(Ehosctl.SystemEnvMock, :get, &Map.get(env, &1))
    :ok
  end
end
