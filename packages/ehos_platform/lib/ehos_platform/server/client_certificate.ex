defmodule EhosPlatform.Server.ClientCertificate do
  @moduledoc """
  The client certificate of one installation administrator, which `EhosPlatform.Server.tunnel/1`
  puts in their kubeconfig in place of k3s's admin file (eh-os D-199).

  The private key is an Ed25519 key made on the workstation, and never leaves it. The request is
  a PKCS #10 CSR for the subject `CN=ehos-administrator:<name>:<id>` with no organization, so the
  certificate names no group. It goes to the cluster as a `CertificateSigningRequest` for the
  signer `kubernetes.io/kube-apiserver-client`, for client authentication, for 12 hours
  (`request/3`). Before ehosctl approves it, `check_request/3` holds what the cluster created to
  what the workstation made; `check_certificate/3` holds the certificate issued to the key.

  OTP's `:public_key` signs and reads the certificates; the CSR's DER is written here, since OTP
  encodes no PKCS #10 request for an Ed25519 key.
  """

  alias EhosPlatform.Failure
  alias EhosPlatform.Server

  @signer "kubernetes.io/kube-apiserver-client"
  @lifetime 43_200
  # A certificate with less than this left is issued again.
  @renew_before 3_600
  @ed25519 {1, 3, 101, 112}
  @common_name {2, 5, 4, 3}

  @typedoc "An Ed25519 private key, as `:public_key` holds it."
  @type key :: tuple()

  @doc "How long a certificate lasts, in seconds."
  @spec lifetime() :: pos_integer()
  def lifetime, do: @lifetime

  @doc "A new Ed25519 private key."
  @spec new_key() :: key()
  def new_key, do: :public_key.generate_key({:namedCurve, :ed25519})

  @doc "`key` as PEM, PKCS #8, as kubectl reads a client key."
  @spec key_pem(key()) :: String.t()
  def key_pem(key),
    do: :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])

  @doc """
  The private key in `pem`, or `nil` when it holds no Ed25519 key.
  """
  @spec read_key(String.t()) :: key() | nil
  def read_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry] -> ed25519(:public_key.pem_entry_decode(entry))
      _other -> nil
    end
  rescue
    _error -> nil
  end

  # PKCS #8 leaves the public key out; it is derived from the private one.
  defp ed25519({:ECPrivateKey, version, private, {:namedCurve, @ed25519} = curve, _, attributes}) do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519, private)
    {:ECPrivateKey, version, private, curve, public, attributes}
  end

  defp ed25519(_other), do: nil

  @doc """
  The CSR, as PEM, for `user` with `key`: the subject `CN=<user>` and nothing else, signed with
  `key`.
  """
  @spec csr(key(), String.t()) :: String.t()
  def csr(key, user) do
    algorithm = seq([oid(@ed25519)])
    name = seq([tlv(0x31, seq([oid(@common_name), tlv(0x0C, user)]))])
    public_key = seq([algorithm, tlv(0x03, <<0, public(key)::binary>>)])
    info = seq([<<2, 1, 0>>, name, public_key, <<0xA0, 0>>])
    signature = :public_key.sign(info, :none, key)
    der = seq([info, algorithm, tlv(0x03, <<0, signature::binary>>)])
    :public_key.pem_encode([{:CertificationRequest, der, :not_encrypted}])
  end

  @doc """
  The `CertificateSigningRequest` named `name` that asks the cluster to sign `csr`.
  """
  @spec request(String.t(), String.t()) :: map()
  def request(name, csr) do
    %{
      "apiVersion" => "certificates.k8s.io/v1",
      "kind" => "CertificateSigningRequest",
      "metadata" => %{"name" => name},
      "spec" => %{
        "request" => Base.encode64(csr),
        "signerName" => @signer,
        "usages" => ["client auth"],
        "expirationSeconds" => @lifetime
      }
    }
  end

  @doc """
  `:ok` when `created`, the `CertificateSigningRequest` the cluster created, is the one this
  workstation asked for: its own CSR, whose subject is `user` alone with `key`'s public key, the
  signer, the usage and the lifetime, and no approval or denial yet. A check against mistakes:
  each installation administrator has root and can approve any CSR.
  """
  @spec check_request(map(), String.t(), {key(), String.t()}) :: :ok | {:error, String.t()}
  def check_request(created, csr, {key, user}) do
    spec = created["spec"] || %{}

    checks = [
      spec["request"] == Base.encode64(csr),
      requested(spec["request"]) == {:ok, [user], public(key)},
      spec["signerName"] == @signer,
      spec["usages"] == ["client auth"],
      spec["expirationSeconds"] == @lifetime,
      get_in(created, ["status", "conditions"]) in [nil, []],
      is_binary(get_in(created, ["metadata", "uid"])),
      is_binary(get_in(created, ["metadata", "resourceVersion"]))
    ]

    if Enum.all?(checks),
      do: :ok,
      else:
        {:error,
         "The certificate signing request on the server is not the one that ehosctl made. " <>
           "ehosctl did not approve it. Run the command again."}
  end

  # The common names and the public key of a CSR in base64 PEM.
  defp requested(base64) do
    with {:ok, pem} <- Base.decode64(base64 || ""),
         [{:CertificationRequest, der, :not_encrypted}] <- :public_key.pem_decode(pem),
         {:CertificationRequest, info, _algorithm, _signature} <-
           :public_key.der_decode(:CertificationRequest, der) do
      {:CertificationRequestInfo, _version, subject, subject_key, _attributes} = info
      {:CertificationRequestInfo_subjectPKInfo, _algorithm, public} = subject_key
      {:ok, names(subject), public}
    else
      _other -> :error
    end
  rescue
    _error -> :error
  end

  # Every attribute of a subject must be one common name: no organization, so no group.
  defp names({:rdnSequence, rdns}) do
    for rdn <- rdns, {:AttributeTypeAndValue, type, value} <- rdn do
      if type == @common_name, do: common_name(value), else: {:other, type}
    end
  end

  defp common_name(<<0x0C, length, name::binary-size(length)>>), do: name
  defp common_name({:utf8String, name}), do: name
  defp common_name(value), do: {:other, value}

  @doc """
  `:ok` when `pem`, the certificate the cluster issued, holds `key`'s public key and names `user`
  alone.
  """
  @spec check_certificate(String.t(), key(), String.t()) :: :ok | {:error, String.t()}
  def check_certificate(pem, key, user) do
    case certificate(pem) do
      {:ok, %{public: public, names: [^user]}} ->
        if public == public(key), do: :ok, else: not_ours()

      _other ->
        not_ours()
    end
  end

  defp not_ours,
    do:
      {:error,
       "The certificate that the server issued is not for the key that ehosctl made. ehosctl " <>
         "did not write the kubeconfig. Run the command again."}

  @doc """
  Whether the certificate `pem` and the key `key_pem` in a kubeconfig still do for `user`: the
  key is the certificate's, the certificate names `user` alone, the client CA in `client_ca` signed
  it, and it is valid for an hour more at `now`. One that does not is issued again.
  """
  @spec usable?(String.t() | nil, String.t() | nil, String.t(), String.t(), DateTime.t()) ::
          boolean()
  def usable?(pem, key_pem, user, client_ca, now) when is_binary(pem) and is_binary(key_pem) do
    with key when key != nil <- read_key(key_pem),
         :ok <- check_certificate(pem, key, user),
         {:ok, %{not_before: not_before, not_after: not_after, der: der}} <- certificate(pem),
         [{:Certificate, ca_der, :not_encrypted} | _rest] <- :public_key.pem_decode(client_ca) do
      DateTime.compare(not_before, now) != :gt and
        DateTime.diff(not_after, now) >= @renew_before and
        :public_key.pkix_is_issuer(der, ca_der) and
        :public_key.pkix_verify(der, ca_public_key(ca_der))
    else
      _other -> false
    end
  rescue
    _error -> false
  end

  def usable?(_pem, _key_pem, _user, _client_ca, _now), do: false

  @doc "When the certificate in `pem` expires, or `nil` when it holds none."
  @spec expires(String.t()) :: DateTime.t() | nil
  def expires(pem) do
    case certificate(pem) do
      {:ok, %{not_after: not_after}} -> not_after
      _other -> nil
    end
  end

  defp certificate(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted} | _rest] -> decoded(der)
      _other -> :error
    end
  rescue
    _error -> :error
  end

  defp decoded(der) do
    otp = :public_key.pkix_decode_cert(der, :otp)
    tbs = elem(otp, 1)
    {:OTPSubjectPublicKeyInfo, _algorithm, public} = elem(tbs, 7)
    {:Validity, not_before, not_after} = elem(tbs, 5)

    {:ok,
     %{
       der: der,
       public: raw(public),
       names: otp_names(elem(tbs, 6)),
       not_before: time(not_before),
       not_after: time(not_after)
     }}
  end

  defp raw({:ECPoint, public}), do: public
  defp raw({:ed_pub, :ed25519, public}), do: public
  defp raw(public) when is_binary(public), do: public
  defp raw(_other), do: <<>>

  defp otp_names({:rdnSequence, rdns}) do
    for rdn <- rdns, {:AttributeTypeAndValue, type, value} <- rdn do
      if type == @common_name, do: otp_name(value), else: {:other, type}
    end
  end

  defp otp_name({:utf8String, name}), do: name
  defp otp_name({:printableString, name}), do: to_string(name)
  defp otp_name(name) when is_binary(name), do: name
  defp otp_name(other), do: {:other, other}

  defp time({:utcTime, time}), do: parse_time("20" <> to_string(time))
  defp time({:generalTime, time}), do: parse_time(to_string(time))

  defp parse_time(
         <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, "Z">>
       ) do
    {:ok, time, 0} = DateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z")
    time
  end

  defp ca_public_key(ca_der) do
    tbs = ca_der |> :public_key.pkix_decode_cert(:otp) |> elem(1)

    # An RSA key is verified with its record alone; an EC key with its point and curve.
    case elem(tbs, 7) do
      {:OTPSubjectPublicKeyInfo, _algorithm, {:RSAPublicKey, _, _} = key} -> key
      {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, _oid, params}, point} -> {point, params}
    end
  end

  @cas_marker "--- ehosctl client ca ---"

  # The server CA, which the kubeconfig verifies the API server with, then the client CA, which
  # signs the administrators' certificates. Both are certificates, readable by root alone where
  # k3s keeps them; neither holds a key.
  @cas_script "sudo cat /var/lib/rancher/k3s/server/tls/server-ca.crt && " <>
                "printf '%s\\n' '#{@cas_marker}' && " <>
                "sudo cat /var/lib/rancher/k3s/server/tls/client-ca.crt"

  # kubectl's errors go to a file, so a warning never lands in the JSON it prints.
  @create_script ~S"""
  e=$(mktemp) || exit 3
  trap 'rm -f "$e"' EXIT
  sudo k3s kubectl create --request-timeout=30s -o json -f - 2>"$e" || { cat "$e"; exit 3; }
  """

  # Standard input: the CSR's name on the first line, then the CSR with its approval. The approval
  # goes to the `approval` subresource with the uid and resourceVersion ehosctl read, so the API
  # server refuses a CSR replaced in between; then the certificate is awaited until 30 seconds after
  # the approval, each request given what is left of them and at least 5 seconds, and printed in
  # base64. A request that fails is tried again while time is left: 4 when no certificate came,
  # with what kubectl said last.
  @approve_script ~S"""
  set -u
  IFS= read -r name
  case "$name" in ''|*[!a-z0-9-]*) exit 2;; esac
  e=$(mktemp) || exit 3
  trap 'rm -f "$e"' EXIT
  sudo k3s kubectl replace --request-timeout=30s --raw "/apis/certificates.k8s.io/v1/certificatesigningrequests/$name/approval" -f - >/dev/null 2>"$e" || { cat "$e"; exit 3; }
  deadline=$(($(date +%s) + 30))
  while :; do
    left=$((deadline - $(date +%s)))
    if [ "$left" -le 0 ]; then cat "$e"; exit 4; fi
    if [ "$left" -lt 5 ]; then left=5; fi
    c=$(sudo k3s kubectl get --request-timeout="${left}s" certificatesigningrequest "$name" -o 'jsonpath={.status.certificate}' 2>"$e") || c=
    if [ -n "$c" ]; then printf '%s\n' "$c"; exit 0; fi
    sleep 1
  done
  """

  @doc """
  The server CA and the client CA of the cluster, as PEM, read over SSH.
  """
  @spec read_cas(Server.t(), String.t()) ::
          {:ok, %{server: String.t(), client: String.t()}} | {:error, Failure.message()}
  def read_cas(server, address) do
    case Server.on_server(server, address, @cas_script) do
      {output, 0} ->
        output |> String.split("\n#{@cas_marker}\n") |> cas()

      result ->
        failed(result, "ehosctl could not read the CAs of the cluster on ehos-#{server.name}.")
    end
  end

  # The split takes the newline that ends the server CA's file.
  defp cas([server_ca, client_ca]), do: {:ok, %{server: server_ca <> "\n", client: client_ca}}
  defp cas(_other), do: unreadable()

  defp unreadable, do: {:error, "The server answered in a form that ehosctl cannot read."}

  @doc """
  Issues a certificate for `user`, the Kubernetes user of an installation administrator, through
  the CSR API (eh-os D-199): a new key, its CSR, the `CertificateSigningRequest` made and checked,
  approved as root over SSH, and the certificate it gives checked. Returns the certificate and
  the key, as PEM.
  """
  @spec issue(Server.t(), String.t(), String.t()) ::
          {:ok, %{certificate: String.t(), key: String.t()}} | {:error, Failure.message()}
  def issue(server, address, user) do
    key = new_key()
    csr = csr(key, user)
    name = request_name(user)
    server.progress.({:step, "Issuing a certificate for #{user}"})

    with {:ok, created} <- create(server, address, request(name, csr)),
         :ok <- check_request(created, csr, {key, user}),
         {:ok, certificate} <- approve(server, address, name, created),
         :ok <- check_certificate(certificate, key, user) do
      {:ok, %{certificate: certificate, key: key_pem(key)}}
    end
  end

  @doc """
  The name of a new CSR for `user`: `ehos-administrator-<name>-<id>-<8 random hexadecimal
  digits>`.
  """
  @spec request_name(String.t()) :: String.t()
  def request_name(user) do
    random = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    (user |> String.replace(":", "-")) <> "-" <> random
  end

  defp create(server, address, request) do
    case Server.on_server(server, address, @create_script, input: Jason.encode!(request)) do
      {output, 0} ->
        output |> Jason.decode() |> created()

      result ->
        failed(
          result,
          "ehosctl could not make the certificate signing request on ehos-#{server.name}."
        )
    end
  end

  @doc """
  `created` with the condition that approves it, as ehosctl writes it to the `approval`
  subresource.
  """
  @spec approved(map()) :: map()
  def approved(created) do
    condition = %{
      "type" => "Approved",
      "status" => "True",
      "reason" => "EhosctlServerTunnel",
      "message" => "Approved by ehosctl server tunnel, for the key that it made."
    }

    created
    |> Map.put("status", %{"conditions" => [condition]})
    |> Map.update("metadata", %{}, &Map.delete(&1, "managedFields"))
  end

  defp approve(server, address, name, created) do
    input = name <> "\n" <> Jason.encode!(approved(created))

    case Server.on_server(server, address, @approve_script, input: input) do
      {output, 0} ->
        output |> String.trim() |> Base.decode64() |> issued()

      {_output, 4} ->
        {:error,
         "The cluster approved the certificate signing request #{name}, but issued no " <>
           "certificate within 30 seconds. Run the command again."}

      result ->
        failed(result, "ehosctl could not approve the certificate signing request #{name}.")
    end
  end

  defp created({:ok, %{} = created}), do: {:ok, created}
  defp created(_other), do: unreadable()

  defp issued({:ok, pem}), do: {:ok, pem}
  defp issued(:error), do: unreadable()

  defp failed({:error, :not_found}, _said),
    do: {:error, "`ssh` is not installed. `ehosctl doctor` says what is missing"}

  defp failed({output, status}, said),
    do:
      {:error,
       Failure.printed(
         String.trim_trailing(said, ".") <> " (exit status #{status}).",
         "ssh",
         output
       )}

  @doc """
  The kubeconfig whose one context, `context`, reaches the API server through the tunnel's local
  `port` and verifies it with the server CA `server_ca`, with the client certificate `pem` and
  the key `key_pem`.
  """
  @spec kubeconfig(String.t(), pos_integer(), String.t(), String.t(), String.t()) :: map()
  def kubeconfig(context, port, server_ca, pem, key_pem) do
    %{
      "apiVersion" => "v1",
      "kind" => "Config",
      "clusters" => [
        %{
          "name" => context,
          "cluster" => %{
            "certificate-authority-data" => Base.encode64(server_ca),
            "server" => "https://127.0.0.1:#{port}"
          }
        }
      ],
      "users" => [
        %{
          "name" => context,
          "user" => %{
            "client-certificate-data" => Base.encode64(pem),
            "client-key-data" => Base.encode64(key_pem)
          }
        }
      ],
      "contexts" => [
        %{"name" => context, "context" => %{"cluster" => context, "user" => context}}
      ],
      "current-context" => context
    }
  end

  defp public({:ECPrivateKey, _version, _private, _curve, public, _attributes}), do: public

  defp oid({a, b, c, d}) when a == 1 and b == 3, do: <<6, 3, 40 * a + b, c, d>>
  defp oid({2, 5, 4, 3}), do: <<6, 3, 85, 4, 3>>

  defp seq(parts), do: tlv(0x30, IO.iodata_to_binary(parts))

  defp tlv(tag, content) do
    length =
      case byte_size(content) do
        size when size < 128 -> <<size>>
        size when size < 256 -> <<0x81, size>>
        size -> <<0x82, size::16>>
      end

    <<tag, length::binary, content::binary>>
  end
end
