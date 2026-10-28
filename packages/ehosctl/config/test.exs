import Config

config :ehosctl, Ehosctl.SystemEnv, impl: Ehosctl.SystemEnvMock
config :ehosctl, Ehosctl.OS, impl: Ehosctl.OSMock
config :ehosctl, Ehosctl.Runner, impl: Ehosctl.RunnerMock
config :ehosctl, Ehosctl.Browser, impl: Ehosctl.BrowserMock
config :ehosctl, Ehosctl.Clock, impl: Ehosctl.ClockMock
config :ehosctl, Ehosctl.Terminal, impl: Ehosctl.TerminalMock
config :ehosctl, Ehosctl.HTTP, impl: Ehosctl.HTTPMock
