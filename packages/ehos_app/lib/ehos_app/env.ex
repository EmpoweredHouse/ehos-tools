defmodule EhosApp.Env do
  @moduledoc """
  The process environment, as a way out (ehos-tools T-20): where `mix ehos_app.review
  pull_request` reads the pull request's description, so a test says what the environment holds
  without setting it. A caller names an implementation in `opts[:env]`, and `EhosApp.EnvImpl`,
  the process's own, is the default.
  """

  @doc "The value of the variable `name`, or `nil` when it is not set."
  @callback get(name :: String.t()) :: String.t() | nil
end

defmodule EhosApp.EnvImpl do
  @moduledoc "The `EhosApp.Env` of this process, read with `System.get_env/1`."

  @behaviour EhosApp.Env

  @impl true
  def get(name), do: System.get_env(name)
end
