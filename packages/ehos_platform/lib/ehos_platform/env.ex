defmodule EhosPlatform.Env do
  @moduledoc """
  The process environment, as a way out (T-20): where a passphrase, a token or a provider's
  account comes from when the caller does not give it, so a test says what the environment holds
  without setting it. A caller names an implementation in `opts[:env]`, and
  `EhosPlatform.EnvImpl`, the process's own, is the default.
  """

  @doc "The value of the variable `name`, or `nil` when it is not set."
  @callback get(name :: String.t()) :: String.t() | nil

  @doc """
  The `EhosPlatform.Env` `opts[:env]` names, else, when it names none or is `nil`,
  `EhosPlatform.EnvImpl`.

  Raises `ArgumentError` when `:env` is not a module, with a message that holds none of it: the
  environment as a map, as `ehosctl` keeps it in its own `opts`, would otherwise reach an error
  message whole.
  """
  @spec from(keyword()) :: module()
  def from(opts) do
    case Keyword.get(opts, :env) do
      nil -> EhosPlatform.EnvImpl
      env when is_atom(env) and not is_boolean(env) -> env
      _other -> raise ArgumentError, ":env must name a module that implements EhosPlatform.Env"
    end
  end
end

defmodule EhosPlatform.EnvImpl do
  @moduledoc "The `EhosPlatform.Env` of this process, read with `System.get_env/1`."

  @behaviour EhosPlatform.Env

  @impl true
  def get(name), do: System.get_env(name)
end
