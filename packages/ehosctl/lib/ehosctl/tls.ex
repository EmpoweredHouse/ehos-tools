defmodule Ehosctl.TLS do
  @moduledoc """
  The options every request `ehosctl` makes over `https` is sent with, and the CA certificates it
  trusts besides the system's: the file `EHOSCTL_CA_FILE` names (T-09), and the CA `ehosctl login`
  kept for the installation a command talks to (T-14).

  Apart from `Ehosctl.SignIn`, which uses it, so a command of the platform plane, which reads
  GitHub's releases through `Ehosctl.HTTP`, never reaches the sign-in code (eh-os D-87).
  """

  # How long `ehosctl` waits for EHOS to answer one request.
  @timeout_ms 30_000

  @type error :: {:error, Ehosctl.Output.kind(), String.t()}

  @doc """
  The options every request is made with: a timeout, and for `https` hostname checking
  and the system's CA certificates, rather than `httpc`'s defaults.

  `EHOSCTL_CA_FILE` in `env` names a PEM file of CA certificates trusted besides the system's, as
  `curl --cacert` names one: a local EHOS's, such as the k3d cluster's `_build/k3d/ca.crt`. It is
  read here, before any connection. A file that is not a regular one of at most 1 MiB, cannot be
  read, or holds no certificate, or one that `:public_key` cannot decode, is an error of kind
  `:invalid` that names it.

  `ca` is the CA `ehosctl login` kept for the installation the command talks to (T-14), as
  `{name, pem}`, trusted besides both; `nil` for none. One that holds no certificate `ehosctl` can
  decode is an error of kind `:failed`, as a `config.json` it cannot read is, that names the
  installation.

  What was trusted besides the system's CAs is kept as `:trusted`, for an error to name
  (`Ehosctl.HTTP.untrusted/3`).
  """
  @spec request_opts(String.t(), %{String.t() => String.t()}, {String.t(), String.t()} | nil) ::
          {:ok, map()} | error()
  def request_opts(issuer, env, ca \\ nil) do
    file = env["EHOSCTL_CA_FILE"]

    with {:ok, from_file} <- ca_file(file),
         {:ok, kept} <- kept_ca(ca) do
      extra = from_file ++ kept

      trusted =
        if(from_file != [], do: [{:file, file}], else: []) ++
          if kept != [], do: [{:kept, elem(ca, 0)}], else: []

      case URI.parse(issuer).scheme do
        "https" ->
          # A handshake that fails is said once, in ehosctl's words, rather than also in the
          # notices :ssl logs.
          ssl =
            :httpc.ssl_verify_host_options(true)
            |> Keyword.update(:cacerts, extra, &(&1 ++ extra))
            |> Keyword.put(:log_level, :none)

          {:ok, %{timeout: @timeout_ms, ssl: ssl, trusted: trusted}}

        _http ->
          {:ok, %{timeout: @timeout_ms, trusted: trusted}}
      end
    end
  end

  # A CA bundle is a few hundred kilobytes at most; the bound keeps a path such as /dev/zero
  # from being read without end.
  @max_ca_file_bytes 1_048_576

  @doc """
  The CA certificates in the file `EHOSCTL_CA_FILE` names in `env`, as PEM, each decoded and
  encoded again, so nothing else in the file is kept: what `ehosctl login` keeps for the
  installation (T-14). `nil` when the variable is not set; an error of kind `:invalid`, as
  `request_opts/3` gives it, for a file it would refuse.
  """
  @spec ca_file_pem(%{String.t() => String.t()}) :: {:ok, String.t() | nil} | error()
  def ca_file_pem(env) do
    with {:ok, ders} <- ca_file(env["EHOSCTL_CA_FILE"]) do
      pem =
        ders != [] &&
          :public_key.pem_encode(for der <- ders, do: {:Certificate, der, :not_encrypted})

      cond do
        ders == [] ->
          {:ok, nil}

        # Encoded again, the certificates can outgrow the file; `config.json` keeps no more.
        byte_size(pem) > @max_ca_file_bytes ->
          {:error, :invalid,
           "EHOSCTL_CA_FILE=#{Ehosctl.Refusal.shown(env["EHOSCTL_CA_FILE"])} holds more " <>
             "certificates than ehosctl keeps for an installation. The limit is " <>
             "#{@max_ca_file_bytes} bytes."}

        true ->
          {:ok, pem}
      end
    end
  end

  defp kept_ca(nil), do: {:ok, []}

  defp kept_ca({name, pem}) do
    case certificates(pem) do
      {:ok, ders} ->
        {:ok, ders}

      _none ->
        {:error, :failed,
         "The CA that ehosctl keeps for #{name} holds no certificate that ehosctl can read. " <>
           "Set EHOSCTL_CA_FILE to the CA of the installation, and sign in to #{name} again."}
    end
  end

  defp ca_file(empty) when empty in [nil, ""], do: {:ok, []}

  # Every certificate is decoded here, and the file refused unless all of them decode, as curl
  # refuses it. :ssl would skip one it cannot decode with a notice on the terminal, which
  # `log_level: :none` does not silence (ssl_pkix_db logs it through :logger), once per
  # connection, and then fail the handshake as though the file had not named its CA.
  defp ca_file(file) do
    shown = "EHOSCTL_CA_FILE=#{Ehosctl.Refusal.shown(file)}"

    with {:ok, %File.Stat{type: :regular}} <- File.stat(file),
         {:ok, pem} <- read_at_most(file, @max_ca_file_bytes),
         {:ok, certificates} <- certificates(pem) do
      {:ok, certificates}
    else
      {:ok, %File.Stat{}} ->
        {:error, :invalid, "#{shown} is not a regular file."}

      :too_large ->
        {:error, :invalid,
         "#{shown} is larger than #{@max_ca_file_bytes} bytes. A CA bundle is smaller."}

      {:error, reason} when is_atom(reason) ->
        {:error, :invalid, "#{shown}: ehosctl cannot read it (#{:file.format_error(reason)})."}

      :undecodable ->
        {:error, :invalid, "#{shown} holds a certificate that ehosctl cannot read."}

      :none ->
        {:error, :invalid, "#{shown} holds no certificate that ehosctl can read."}
    end
  end

  # The bound is on what is read, not on the size `File.stat` gave: a file may grow between the
  # two, and one under /proc reports a size of 0.
  defp read_at_most(file, max) do
    with {:ok, device} <- File.open(file, [:read, :binary]) do
      try do
        case IO.binread(device, max + 1) do
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, reason}
          read when byte_size(read) > max -> :too_large
          read -> {:ok, read}
        end
      after
        File.close(device)
      end
    end
  end

  defp certificates(pem) do
    ders = pem_certificates(pem)

    case Enum.count(ders, &certificate?/1) do
      0 -> :none
      decoded when decoded == length(ders) -> {:ok, ders}
      _some -> :undecodable
    end
  end

  defp pem_certificates(pem) do
    for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der
  rescue
    _malformed -> []
  end

  # As :ssl decodes a CA certificate before it trusts it.
  defp certificate?(der) do
    _certificate = :public_key.pkix_decode_cert(der, :otp)
    true
  rescue
    _undecodable -> false
  end
end
