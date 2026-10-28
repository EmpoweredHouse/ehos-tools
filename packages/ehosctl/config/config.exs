import Config

# Each behaviour's implementation is named in the environment's own file, and only there (T-20):
# one whose line test.exs lacks fails to compile, rather than reaching a real keychain, program or
# installation from a test.
import_config "#{config_env()}.exs"
