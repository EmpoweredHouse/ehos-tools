import Config

config :ehosctl, Ehosctl.SystemEnv, impl: Ehosctl.SystemEnvImpl
config :ehosctl, Ehosctl.OS, impl: Ehosctl.OSImpl
config :ehosctl, Ehosctl.Runner, impl: Ehosctl.RunnerImpl
