defmodule Ehosctl.Mocks do
  @moduledoc """
  The mocks of ehosctl's ways out (T-20), each named in `config/test.exs`, where its behaviour's
  `current/0` reads. `Ehosctl.Case` stubs them with what a test gets unless it says otherwise.
  `Ehosctl.CommandRunnerMock` is the exception: `ehos_platform` takes its runner in `opts`, so a
  test of a platform command gives it there.
  """

  Hammox.defmock(Ehosctl.BrowserMock, for: Ehosctl.Browser)
  Hammox.defmock(Ehosctl.CommandRunnerMock, for: EhosPlatform.CommandRunner)
  Hammox.defmock(Ehosctl.ClockMock, for: Ehosctl.Clock)
  Hammox.defmock(Ehosctl.HTTPMock, for: Ehosctl.HTTP)
  Hammox.defmock(Ehosctl.OSMock, for: Ehosctl.OS)
  Hammox.defmock(Ehosctl.RunnerMock, for: Ehosctl.Runner)
  Hammox.defmock(Ehosctl.SignInMock, for: Ehosctl.SignIn)
  Hammox.defmock(Ehosctl.SystemEnvMock, for: Ehosctl.SystemEnv)
  Hammox.defmock(Ehosctl.SystemKeychainMock, for: Ehosctl.SystemKeychain)
  Hammox.defmock(Ehosctl.TerminalMock, for: Ehosctl.Terminal)
  Hammox.defmock(Ehosctl.TunnelMock, for: EhosTunnel.Client)
end
