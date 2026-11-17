defmodule Ehosctl.TestCA do
  @moduledoc "Self-signed CA certificates for the tests of the CAs `ehosctl` keeps (`Ehosctl.DataCa`)."

  @doc "A self-signed CA certificate named `name` for `key`, in PEM."
  @spec certificate(String.t(), tuple()) :: String.t()
  def certificate(name, key) do
    %{cert: der} = :public_key.pkix_test_root_cert(String.to_charlist(name), [{:key, key}])
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end
end
