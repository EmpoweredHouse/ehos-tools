defmodule Ehosctl.ServerAdministrators do
  @moduledoc """
  The installation administrators of a server, as `ehosctl server admin` and `ehosctl doctor` ask
  for them: a way out, since each call reaches the server over SSH (T-20). The implementation is
  `EhosPlatform.Server.Administrators`'s; tests mock it.
  """

  @doc "Adds the administrator `name` with the public key in the file at `public_key`."
  @callback add(name :: String.t(), public_key :: Path.t(), opts :: keyword()) ::
              EhosPlatform.Server.result()

  @doc "Removes the administrator `name`, or `shared`."
  @callback remove(name :: String.t(), opts :: keyword()) :: EhosPlatform.Server.result()

  @doc "Lists the administrators, the keys that name nobody, the other subjects and the CSRs."
  @callback list(opts :: keyword()) :: EhosPlatform.Server.result()

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Ehosctl.ServerAdministratorsImpl do
  @moduledoc """
  The `Ehosctl.ServerAdministrators` that reaches the server, through
  `EhosPlatform.Server.Administrators`.
  """

  @behaviour Ehosctl.ServerAdministrators

  alias EhosPlatform.Server.Administrators

  @impl true
  defdelegate add(name, public_key, opts), to: Administrators

  @impl true
  defdelegate remove(name, opts), to: Administrators

  @impl true
  defdelegate list(opts), to: Administrators
end
