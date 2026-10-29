import Config

config :ehosctl, Ehosctl.SystemEnv, impl: Ehosctl.SystemEnvImpl
config :ehosctl, Ehosctl.OS, impl: Ehosctl.OSImpl
config :ehosctl, Ehosctl.Runner, impl: Ehosctl.RunnerImpl
config :ehosctl, Ehosctl.Browser, impl: Ehosctl.BrowserImpl
config :ehosctl, Ehosctl.Clock, impl: Ehosctl.ClockImpl
config :ehosctl, Ehosctl.Terminal, impl: Ehosctl.TerminalImpl
config :ehosctl, Ehosctl.HTTP, impl: Ehosctl.HTTPImpl
config :ehosctl, Ehosctl.SignIn, impl: Ehosctl.SignInImpl
config :ehosctl, Ehosctl.SystemKeychain, impl: Ehosctl.SystemKeychainImpl
