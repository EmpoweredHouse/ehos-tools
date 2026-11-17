defmodule EhosTunnel do
  @moduledoc """
  The data tunnel's wire, one copy for the data gateway, eh-os's tests and `ehosctl` (eh-os D-179,
  D-180): `EhosTunnel.Key` (a session's P-256 key, its `publicKey` and fingerprint),
  `EhosTunnel.Certificate` (the self-signed certificate a client presents),
  `EhosTunnel.Protocol` (the path, the subprotocol, the refusals, the close codes and the bounds),
  and `EhosTunnel.Client` (a local port whose connections each go through a tunnel).
  """

  @doc "This package's `release.json` (eh-os D-91): what it is, with nothing it produces or accepts."
  @spec release(String.t()) :: map()
  def release(commit) when is_binary(commit) do
    %{
      "schema" => "ehos.release/v1",
      "component" => "ehos_tunnel",
      "version" => to_string(Application.spec(:ehos_tunnel, :vsn)),
      "commit" => commit,
      "produces" => [],
      "accepts" => [],
      "requires" => %{}
    }
  end
end
