defmodule Ehosctl.SystemEnv do
  @moduledoc """
  The process environment, as a way out (T-20): where an installation, a state directory, a CA
  file or a token comes from when no flag gives it, so a test says what the environment holds
  without setting it. `current/0` is the implementation the configuration names: this process's
  (`Ehosctl.SystemEnvImpl`), or the tests' mock.
  """

  @doc "The value of the variable `name`, or `nil` when it is not set."
  @callback get(name :: String.t()) :: String.t() | nil

  @doc "Every variable, as a map of names to values, for code that reads several."
  @callback all() :: %{optional(String.t()) => String.t()}

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Ehosctl.SystemEnvImpl do
  @moduledoc "The `Ehosctl.SystemEnv` of this process, read with `System.get_env/0,1`."

  @behaviour Ehosctl.SystemEnv

  @impl true
  def get(name), do: System.get_env(name)

  @impl true
  def all, do: System.get_env()
end
