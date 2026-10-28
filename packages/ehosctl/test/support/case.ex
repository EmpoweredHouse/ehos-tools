defmodule Ehosctl.Case do
  @moduledoc """
  `ExUnit.Case` with the mocks of ehosctl's ways out (T-20) imported and verified on exit. Each
  test starts with an empty environment (`Ehosctl.SystemEnv`), which one that needs a variable
  gives with `stub_env/1`, and this machine's answers to `Ehosctl.OS`, which one that must say
  them stubs or expects. `Ehosctl.Runner` has no default: a test that runs a program says so.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Hammox
      import Ehosctl.Case, only: [stub_env: 1]

      setup :verify_on_exit!
    end
  end

  setup do
    Hammox.stub_with(Ehosctl.OSMock, Ehosctl.OSImpl)
    stub_env(%{})
  end

  @doc "Makes the environment `env`, a map of names to values, for this test's processes."
  @spec stub_env(%{String.t() => String.t()}) :: :ok
  def stub_env(env) do
    Hammox.stub(Ehosctl.SystemEnvMock, :all, fn -> env end)
    Hammox.stub(Ehosctl.SystemEnvMock, :get, &Map.get(env, &1))
    :ok
  end
end
