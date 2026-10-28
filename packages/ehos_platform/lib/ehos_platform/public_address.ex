defmodule EhosPlatform.PublicAddress do
  @moduledoc """
  A service on the internet that answers with the IPv4 address a request came from, as a way out
  (T-20): `EhosPlatform.Server.up/1` asks several, more than once each, to learn the addresses SSH
  is admitted from (ehos-tools#157), and a test says what they answer. A caller names an
  implementation in `opts[:public_address]`, and `EhosPlatform.PublicAddressImpl`, which asks
  over HTTPS, is the default.
  """

  @doc """
  Asks the service at the URL `service` which address this machine reached it from: `{:ok,
  address}`, a dotted IPv4 address, or `{:error, reason}`, a sentence that names no value but the
  service's status.
  """
  @callback ask(service :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
end

defmodule EhosPlatform.PublicAddressImpl do
  @moduledoc "The `EhosPlatform.PublicAddress` that asks the service over HTTPS, with Req."

  @behaviour EhosPlatform.PublicAddress

  # `connection: close`, so that each ask opens a connection of its own rather than reusing the
  # pool's, which would leave through the same address every time. No redirect is followed: an
  # answer that came over plain HTTP could admit anyone's address.
  @impl true
  def ask(service) do
    with {:ok, _apps} <- Application.ensure_all_started(:req),
         {:ok, %Req.Response{status: 200, body: body}} <-
           Req.get(service,
             headers: [{"connection", "close"}],
             redirect: false,
             retry: false,
             connect_options: [timeout: 5_000],
             receive_timeout: 10_000
           ),
         true <- is_binary(body) || {:error, "it answered no text"},
         address = String.trim(body),
         {:ok, _ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)) do
      {:ok, address}
    else
      {:ok, %Req.Response{status: status}} -> {:error, "it answered #{status}"}
      {:error, %{__exception__: true} = error} -> {:error, Exception.message(error)}
      {:error, :einval} -> {:error, "it answered something that is not an IPv4 address"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
