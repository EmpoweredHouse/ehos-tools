defmodule Ehosctl.Case do
  @moduledoc """
  `ExUnit.Case` with the mocks of ehosctl's ways out (T-20) imported and verified on exit. Each
  test starts with an empty environment (`Ehosctl.SystemEnv`); one that needs a variable gives it
  with `stub_env/1`.
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
