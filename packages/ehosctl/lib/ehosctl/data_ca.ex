defmodule Ehosctl.DataCa do
  @moduledoc """
  The two CAs a person's data session is reached through, which `ehosctl` keeps for an
  installation from the first time it reads them on a machine, beyond logging out (eh-os
  [D-149](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0149-a-person-s-database-session-reaches-its-instance-through-a-data-gateway-of-its-own-not-the-governance-plane.md),
  [D-181](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0181-the-data-gateway-s-certificate-comes-from-a-ca-the-chart-makes-which-ehosctl-keeps-from-its-first-login-as-it-keeps-the-data-ca.md)):

    * the **data CA**, which signs the database instances' certificates, which `psql` verifies;
    * the **gateway CA**, which signs the data gateway's certificate, which the tunnel verifies.

  EHOS gives both at `GET /api/v1/data-ca` and in a session's answer, each as its certificate in
  PEM and the SHA-256 of its key's `SubjectPublicKeyInfo` in base64, its fingerprint. `ehosctl`
  reads them at `ehosctl login`. A CA whose key is the kept one's is taken, so a renewed
  certificate replaces the old; one with another key is not, since a governance plane taken over
  could give it. The person takes a new key with `ehosctl db trust-ca FINGERPRINT`, typing the
  fingerprint the installation's administrator gave them outside EHOS.

  They are kept in `config.json`, beside the installation, as `"data_ca"` and `"gateway_ca"`:
  `{"certificate": "<PEM>", "key_sha256": "<base64>"}`.
  """

  alias Ehosctl.Api
  alias Ehosctl.Config

  @typedoc "Which CA: the data CA or the gateway CA."
  @type kind :: :data | :gateway

  @typedoc "A CA as EHOS gives it and `ehosctl` keeps it: its certificate in PEM and its fingerprint."
  @type ca :: %{certificate: String.t(), key_sha256: String.t()}

  @typedoc """
  What reading the CAs did, for each kind: `:kept` (the first, or one with the kept key),
  `{:changed, offered}` (another key, not taken), or `:none` (the installation gives none).
  """
  @type outcome :: :kept | {:changed, ca()} | :none

  @kinds [:data, :gateway]
  @fields %{data: "dataCa", gateway: "gatewayCa"}
  @path "/api/v1/data-ca"

  @doc "The two kinds, in the order `ehosctl` names them."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The CA in `given`, an object of EHOS's answer (`{"certificate": …, "keySha256": …}`), when its
  PEM holds exactly one certificate and the fingerprint is that certificate's; `:error` for
  anything else, which is not taken. A PEM with a second certificate is refused, as `psql` would
  trust each one.
  """
  @spec parse(term()) :: {:ok, ca()} | :error
  def parse(%{"certificate" => pem, "keySha256" => key_sha256})
      when is_binary(pem) and is_binary(key_sha256) do
    case fingerprint(pem) do
      {:ok, ^key_sha256} -> {:ok, %{certificate: pem, key_sha256: key_sha256}}
      _other -> :error
    end
  end

  def parse(_given), do: :error

  @doc """
  The fingerprint of the one certificate in `pem`: the SHA-256 of its `SubjectPublicKeyInfo`, as
  it was signed, in base64.
  """
  @spec fingerprint(String.t()) :: {:ok, String.t()} | :error
  def fingerprint(pem) do
    with [{:Certificate, der, :not_encrypted}] <- safe_pem_decode(pem),
         {:ok, spki} <- spki(der) do
      {:ok, Base.encode64(:crypto.hash(:sha256, spki))}
    else
      _other -> :error
    end
  end

  defp safe_pem_decode(pem) do
    :public_key.pem_decode(pem)
  rescue
    _error -> []
  end

  # Field 7 of the plain TBSCertificate record of public_key's OTP-PUB-KEY.hrl, encoded again as
  # it was signed; as EHOS computes the fingerprint it gives.
  defp spki(der) do
    {:Certificate, tbs, _algorithm, _signature} = :public_key.pkix_decode_cert(der, :plain)
    {:ok, :public_key.der_encode(:SubjectPublicKeyInfo, elem(tbs, 7))}
  rescue
    _error -> :error
  end

  @doc """
  The fingerprint a person typed, as base64, as EHOS gives it: base64, or the SHA-256 in
  hexadecimal, with or without colons, as `openssl` prints one. `:error` when it is neither.

      iex> Ehosctl.DataCa.typed(" qUiQTy8PR5uPgZdpSzAYSw0u0cHNKh7A+4XSmaGSpEc= ")
      {:ok, "qUiQTy8PR5uPgZdpSzAYSw0u0cHNKh7A+4XSmaGSpEc="}

      iex> Ehosctl.DataCa.typed("A9:48:90:4F" <> String.duplicate(":00", 28))
      {:ok, Base.encode64(<<0xA9, 0x48, 0x90, 0x4F>> <> :binary.copy(<<0>>, 28))}

      iex> Ehosctl.DataCa.typed("not a fingerprint")
      :error
  """
  @spec typed(String.t()) :: {:ok, String.t()} | :error
  def typed(text) do
    text = String.trim(text)
    hex = String.replace(text, ":", "")

    with {:hex, :error} <- {:hex, Base.decode16(hex, case: :mixed)},
         {:ok, <<_::binary-size(32)>> = sha256} <- Base.decode64(text) do
      {:ok, Base.encode64(sha256)}
    else
      {:hex, {:ok, <<_::binary-size(32)>> = sha256}} -> {:ok, Base.encode64(sha256)}
      _other -> :error
    end
  end

  @doc """
  The CA of `kind` kept for `installation` (`Ehosctl.Config.select/3`'s), `nil` when none is
  kept, or an error when `config.json` holds one `ehosctl` cannot read.
  """
  @spec kept({Config.name(), Config.installation()}, kind()) ::
          {:ok, ca() | nil} | {:error, :failed, Ehosctl.Failure.message()}
  def kept({name, installation}, kind) do
    with %{} = kept <- installation[key(kind)],
         {:ok, ca} <- stored_ca(kept) do
      {:ok, ca}
    else
      nil -> {:ok, nil}
      _unreadable -> unreadable(name, kind)
    end
  end

  # Only the two fields `stored/1` writes, and a certificate that has the fingerprint beside it.
  defp stored_ca(%{"certificate" => pem, "key_sha256" => key_sha256} = kept)
       when map_size(kept) == 2,
       do: parse(%{"certificate" => pem, "keySha256" => key_sha256})

  defp stored_ca(_kept), do: :error

  defp unreadable(name, kind),
    do:
      {:error, :failed,
       Ehosctl.Failure.new(
         "The #{label(kind)} that ehosctl keeps for #{name} in config.json is not a CA it can " <>
           "read.",
         advice: "Remove \"#{key(kind)}\" from it, then sign in again:",
         to_do: ["ehosctl login --installation #{name}"]
       )}

  @doc "The key under which `config.json` keeps the CA of `kind`."
  @spec key(kind()) :: String.t()
  def key(kind), do: Config.data_ca_key(kind)

  @doc "The CA of `kind`, as a person reads it: `data CA` or `gateway CA`."
  @spec label(kind()) :: String.t()
  def label(:data), do: "data CA"
  def label(:gateway), do: "gateway CA"

  @doc """
  What `offered` does to `kept`, both CAs of one kind or `nil`: `:kept` when the CA is taken (none
  was kept, or it has the kept key), `{:changed, offered}` when its key is another, `:none` when
  nothing is offered.

      iex> ca = %{certificate: "pem", key_sha256: "a"}
      iex> Ehosctl.DataCa.compare(nil, ca)
      :kept
      iex> Ehosctl.DataCa.compare(ca, %{ca | certificate: "renewed"})
      :kept
      iex> Ehosctl.DataCa.compare(ca, %{certificate: "other", key_sha256: "b"})
      {:changed, %{certificate: "other", key_sha256: "b"}}
  """
  @spec compare(ca() | nil, ca() | nil) :: outcome()
  def compare(_kept, nil), do: :none
  def compare(nil, _offered), do: :kept
  def compare(%{key_sha256: key}, %{key_sha256: key}), do: :kept
  def compare(_kept, offered), do: {:changed, offered}

  @doc """
  Reads the CAs `installation` gives at `GET /api/v1/data-ca`, as `Ehosctl.Api.read/3` reads with
  `opts`, and keeps in `opts[:config_dir]` each one `compare/2` takes. Returns what it did for each
  kind; an installation that runs no data gateway (EHOS's `not_found`) or is older than the route
  gives none, and keeps what was kept. A failure to keep them, of `config.json`'s read or write
  after the CAs were read, is `{:not_kept, error}`, so that the person is told what failed.
  """
  @spec refresh({Config.name(), Config.installation()}, keyword()) ::
          {:ok, %{kind() => outcome()}} | Api.error() | {:not_kept, Config.error()}
  def refresh({name, %{"url" => url}} = selected, opts) do
    with {:ok, offered} <- offered(selected, opts),
         {:ok, written} <- kept_config(opts, &keep(&1, name, url, offered)) do
      outcomes(written, name, url, offered)
    end
  end

  defp kept_config(opts, change) do
    case Config.update(Keyword.fetch!(opts, :config_dir), change) do
      {:ok, _read, written} -> {:ok, written}
      error -> {:not_kept, error}
    end
  end

  @doc """
  The CAs `installation` gives at `GET /api/v1/data-ca`, each `nil` when it gives none: an
  installation that runs no data gateway answers `not_found`, and one older than the route lacks
  it. A CA that is not one certificate with its own fingerprint is an error.
  """
  @spec offered({Config.name(), Config.installation()}, keyword()) ::
          {:ok, %{kind() => ca() | nil}} | Api.error()
  def offered(installation, opts) do
    case Api.read_if_routed(installation, @path, opts) do
      {:ok, body} -> parsed(body, installation)
      {:lacking, _message} -> {:ok, %{data: nil, gateway: nil}}
      {:error, _kind, _message, %{"code" => "not_found"}} -> {:ok, %{data: nil, gateway: nil}}
      error -> error
    end
  end

  @doc """
  The CAs of a session's answer, or of `GET /api/v1/data-ca`'s, `body`, each `nil` when it is
  `null` or missing; an error naming `installation` when one is there but is not a CA.
  """
  @spec parsed(map(), {Config.name(), Config.installation()}) ::
          {:ok, %{kind() => ca() | nil}} | {:error, :failed, Ehosctl.Failure.message()}
  def parsed(body, {name, _installation}) do
    Enum.reduce_while(@kinds, {:ok, %{}}, fn kind, {:ok, acc} ->
      case parsed_one(body[@fields[kind]]) do
        {:ok, ca} ->
          {:cont, {:ok, Map.put(acc, kind, ca)}}

        :error ->
          {:halt,
           {:error, :failed,
            "#{name} gave a #{label(kind)} that is not one certificate with its own " <>
              "fingerprint, so ehosctl does not trust it."}}
      end
    end)
  end

  defp parsed_one(nil), do: {:ok, nil}
  defp parsed_one(given), do: parse(given)

  # Under `config.json`'s lock, the installation may have moved to another address since the CAs
  # were read, by another sign-in: they are kept only for the address they came from.
  defp keep(config, name, url, offered) do
    {:ok, Enum.reduce(@kinds, config, &keep_one(&2, name, url, &1, offered[&1]))}
  end

  defp keep_one(config, _name, _url, _kind, nil), do: config

  defp keep_one(config, name, url, kind, offered) do
    installation = config.installations[name]

    if match?(%{"url" => ^url}, installation) and taken?(installation[key(kind)], offered),
      do: Config.put_data_ca(config, name, kind, offered),
      else: config
  end

  # A kept CA `ehosctl` cannot read is not replaced: `kept/2` says so to the person.
  defp taken?(nil, _offered), do: true
  defp taken?(%{"key_sha256" => key}, %{key_sha256: key}), do: true
  defp taken?(_kept, _offered), do: false

  # An installation that moved meanwhile kept nothing of these, and says nothing about them.
  defp outcomes(config, name, url, offered) do
    outcomes_at(config.installations[name], name, url, offered)
  end

  defp outcomes_at(%{"url" => url} = installation, name, url, offered) do
    installation = {name, installation}

    Enum.reduce_while(@kinds, {:ok, %{}}, fn kind, {:ok, acc} ->
      case kept(installation, kind) do
        {:ok, kept} -> {:cont, {:ok, Map.put(acc, kind, compare(kept, offered[kind]))}}
        error -> {:halt, error}
      end
    end)
  end

  defp outcomes_at(_moved, _name, _url, _offered), do: {:ok, %{data: :none, gateway: :none}}

  @doc """
  What a person is told about `outcomes` after `ehosctl login` to `name`: a warning, its head
  and its explanation, for each CA whose key changed, and none when nothing did.
  """
  @spec warnings(Config.name(), %{kind() => outcome()}) :: [{String.t(), String.t()}]
  def warnings(name, outcomes) do
    for kind <- @kinds, match?({:changed, _offered}, outcomes[kind]) do
      changed_parts(name, kind)
    end
  end

  @doc """
  The sentence for a CA of `kind` whose key is not the kept one: what `ehosctl` does, and how the
  person takes the new one.
  """
  @spec changed(Config.name(), kind()) :: String.t()
  def changed(name, kind) do
    {head, explanation} = changed_parts(name, kind)
    head <> " " <> explanation
  end

  defp changed_parts(name, kind),
    do:
      {"#{name} gives a #{label(kind)} with another key than the one ehosctl keeps.",
       "ehosctl does not trust it, and refuses data sessions that use it. If your " <>
         "installation's administrator told you that the key changed, and gave you its " <>
         "fingerprint, run `ehosctl db trust-ca FINGERPRINT` with it."}
end
