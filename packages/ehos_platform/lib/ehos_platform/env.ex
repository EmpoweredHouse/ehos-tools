defmodule EhosPlatform.Env do
  @moduledoc """
  The process environment, as a way out (T-20): where a passphrase, a token or a provider's
  account comes from when the caller does not give it, so a test says what the environment holds
  without setting it. A caller names an implementation in `opts[:env]`, and
  `EhosPlatform.EnvImpl`, the process's own, is the default.
  """

  @doc "The value of the variable `name`, or `nil` when it is not set."
  @callback get(name :: String.t()) :: String.t() | nil
end

defmodule EhosPlatform.EnvImpl do
  @moduledoc "The `EhosPlatform.Env` of this process, read with `System.get_env/1`."

  @behaviour EhosPlatform.Env

  @impl true
  def get(name), do: System.get_env(name)
end
