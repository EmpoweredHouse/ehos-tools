defmodule Ehosctl.Mocks do
  @moduledoc """
  The mocks of ehosctl's ways out (T-20), each named in `config/test.exs`, where its behaviour's
  `current/0` reads. `Ehosctl.Case` stubs them with what a test gets unless it says otherwise.
  """

  Hammox.defmock(Ehosctl.SystemEnvMock, for: Ehosctl.SystemEnv)
end
