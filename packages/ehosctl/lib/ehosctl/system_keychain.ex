defmodule Ehosctl.SystemKeychain do
  @moduledoc """
  The system's keychain, as a way out (T-20): the `Ehosctl.TokenStore` backend that keeps a
  refresh token in it, or none. `Ehosctl.TokenStore.choose/2` then picks between it and the file
  (T-08). A test mocks it, so no test reaches a real keychain.
  """

  @doc "The backend for this system's keychain, or `nil` when it has none `ehosctl` can use."
  @callback backend() :: module() | nil

  @impl_module Application.compile_env!(:ehosctl, [__MODULE__, :impl])

  @doc "The implementation the configuration chose."
  @spec current() :: module()
  def current, do: @impl_module
end

defmodule Ehosctl.SystemKeychainImpl do
  @moduledoc """
  The `Ehosctl.SystemKeychain` of this machine: macOS's keychain through `security`, Linux's
  Secret Service through `secret-tool` when it is installed, or none.
  """

  @behaviour Ehosctl.SystemKeychain

  alias Ehosctl.TokenStore

  @impl true
  def backend do
    case :os.type() do
      {:unix, :darwin} ->
        TokenStore.Keychain

      {:unix, :linux} ->
        if Ehosctl.OS.current().find_executable("secret-tool"), do: TokenStore.SecretService

      _other ->
        nil
    end
  end
end
