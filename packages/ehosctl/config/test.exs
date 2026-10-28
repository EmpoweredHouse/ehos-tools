import Config

config :ehosctl, Ehosctl.SystemEnv, impl: Ehosctl.SystemEnvMock
config :ehosctl, Ehosctl.OS, impl: Ehosctl.OSMock
config :ehosctl, Ehosctl.Runner, impl: Ehosctl.RunnerMock
