defmodule EhosPlatform.CertificateLog do
  @moduledoc """
  The public Certificate Transparency logs, as a way out (T-20): before an installation gets public
  certificates, `EhosPlatform.DomainRecords` lists the certificates already issued for its host or
  a wildcard above it (eh-os D-158), and a test says what the logs hold. A caller names an
  implementation in `opts[:certificate_log]`, and `EhosPlatform.CertificateLogImpl`, which asks
  crt.sh, is the default.
  """

  @typedoc "A certificate the logs hold: the names it is for, who issued it, and when it ends."
  @type certificate :: %{names: [String.t()], issuer: String.t(), not_after: String.t()}

  @doc """
  The certificates the logs hold that are not expired and name `name` exactly, a wildcard name
  among them: `{:ok, certificates}`, or `{:error, reason}`, a sentence, when the logs did not
  answer.
  """
  @callback certificates(name :: String.t()) :: {:ok, [certificate()]} | {:error, String.t()}
end

defmodule EhosPlatform.CertificateLogImpl do
  @moduledoc """
  The `EhosPlatform.CertificateLog` that asks crt.sh, Sectigo's search of the public logs, with Req.
  crt.sh is often slow, so its answer is waited for at most 30 seconds, and a caller treats no
  answer as a warning.
  """

  @behaviour EhosPlatform.CertificateLog

  @impl true
  def certificates(name) do
    with {:ok, _apps} <- Application.ensure_all_started(:req),
         {:ok, %Req.Response{status: 200, body: body}} <-
           Req.get("https://crt.sh/",
             params: [identity: name, output: "json", exclude: "expired", deduplicate: "Y"],
             retry: false,
             connect_options: [timeout: 10_000],
             receive_timeout: 30_000
           ),
         true <- is_list(body) || {:error, "crt.sh answered something other than a list"} do
      {:ok, for(%{} = entry <- body, do: certificate(entry))}
    else
      {:ok, %Req.Response{status: status}} -> {:error, "crt.sh answered #{status}"}
      {:error, %{__exception__: true} = error} -> {:error, Exception.message(error)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp certificate(entry) do
    %{
      names: entry |> Map.get("name_value", "") |> to_string() |> String.split("\n", trim: true),
      issuer: entry |> Map.get("issuer_name", "") |> to_string(),
      not_after: entry |> Map.get("not_after", "") |> to_string()
    }
  end
end
