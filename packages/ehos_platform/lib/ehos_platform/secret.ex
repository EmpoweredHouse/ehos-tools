defmodule EhosPlatform.Secret do
  @moduledoc """
  A secret that a command made, kept or relied on, and the one list of kinds of secret, so that
  each kind is described with the same words in every command (ehos-tools T-30).

  A `t:t/0` is what a command reports about one secret, in `EhosPlatform.Report`'s `secrets`:
  its `kind`, its `place` and if the run is `new?` for it. The place is a path, a
  `namespace/name`, the system keychain or a variable's name, never derived from the value, so
  a report holds no secret value. `read_from` is the file the run read the value from, for a
  secret the cluster keeps, which makes the run new for that secret whatever `new?` says.

  Each kind has a label, the weight (what a leak or a loss does, in one sentence) and a keeper:

    * `:shared`: the password manager that the installation administrators share;
    * `:own`: the person alone;
    * `:one_person`: the one person it is for;
    * `:cluster`: nobody, the cluster keeps it;
    * `:none`: nobody, it ends with the session or within 10 minutes;
    * `:public`: anyone may have it.

  `warning/1` says when a person must act: on a run that is new for a secret that the person
  keeps, and on one that read a value the cluster keeps from a file.
  """

  @enforce_keys [:kind, :place]
  defstruct [:kind, :place, new?: false, read_from: nil]

  @type kind ::
          :state_passphrase
          | :encrypted_state
          | :ssh_key
          | :kubeconfig
          | :ca_key
          | :ca_certificate
          | :acme_account_key
          | :acme_dns_account
          | :pull_credential
          | :smtp_password
          | :openbao_key
          | :console_tls_key
          | :refresh_token
          | :cached_credentials
          | :printed_credential
          | :data_session_password
          | :invitation_link
          | :external_database_role
          | :application_secret
          | :trusted_ca

  @type keeper :: :shared | :own | :one_person | :cluster | :none | :public

  @type t :: %__MODULE__{
          kind: kind(),
          place: String.t(),
          new?: boolean(),
          read_from: String.t() | nil
        }

  @guide "https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md"
  @share "#{@guide}#share-an-installation-with-another-installation-administrator"
  @openbao "#{@guide}#backing-up-and-restoring-openbao"

  # Each kind: its label, its weight, its keeper, a sentence of its own after the keeper's (or
  # nil), and the section of the installation guide with the procedure (or nil).
  @kinds [
    state_passphrase:
      {"State passphrase",
       "Without the state passphrase, ehosctl cannot change or remove the server.", :shared, nil,
       @share},
    encrypted_state:
      {"Encrypted state",
       "Without a current copy of the state, ehosctl cannot change or remove the server.",
       :shared, "Copy it again after each ehosctl server up.", @share},
    ssh_key:
      {"SSH key", "The SSH key gives a shell on the server, as root.", :shared, nil, @share},
    kubeconfig:
      {"Kubeconfig", "The kubeconfig gives administrator access to the cluster.", :own,
       "Do not copy it: ehosctl server tunnel writes it again.", nil},
    ca_key:
      {"CA key",
       "With the key of the installation's CA, a person can make certificates that ehosctl and pipelines trust.",
       :cluster, nil, nil},
    ca_certificate: {"CA", "Anyone may have the certificate of the CA.", :public, nil, nil},
    acme_account_key:
      {"Let's Encrypt account key",
       "With a Let's Encrypt account key, a person can get certificates for the console's addresses.",
       :cluster, nil, nil},
    acme_dns_account:
      {"acme-dns account",
       "With the acme-dns account, a person can answer the DNS challenge of the installation's domain.",
       :cluster, nil, nil},
    pull_credential:
      {"Pull credential",
       "The cluster pulls the images of EHOS with your GitHub token until another person runs ehosctl install.",
       :own, "Each person with the kubeconfig can read the token.", nil},
    smtp_password:
      {"SMTP password", "With the SMTP password, a person can send mail as the installation.",
       :cluster, nil, nil},
    openbao_key:
      {"OpenBao's key",
       "Without OpenBao's key, nobody can read the secret values in OpenBao or in its snapshots.",
       :shared, "Keep it in another place than the snapshots.", @openbao},
    console_tls_key:
      {"Console TLS key", "With the TLS key of the console, a person can answer as the console.",
       :cluster, nil, nil},
    refresh_token:
      {"Sign-in",
       "With the refresh token, a person acts as you until it expires or you run ehosctl logout.",
       :own, nil, nil},
    cached_credentials:
      {"Credentials", "With a cached credential, a person acts as you for up to 10 minutes.",
       :none, nil, nil},
    printed_credential:
      {"Credential", "With the credential, a person acts as you for up to 10 minutes.", :none,
       nil, nil},
    data_session_password:
      {"Password",
       "With the password, a person reads the data of the application until the session ends.",
       :none, nil, nil},
    invitation_link:
      {"Link", "The link is a password: it signs in as that person one time, within 15 minutes.",
       :one_person, nil, nil},
    external_database_role:
      {"Managing role",
       "With the password of the managing role, a person can manage that database.", :cluster,
       nil, nil},
    application_secret:
      {"Secret", "With the value, a person has the access that it gives to the application.",
       :cluster, nil, nil},
    trusted_ca: {"Trusted CA", "Anyone may have the certificate of a CA.", :public, nil, nil}
  ]

  @keepers %{
    shared: "Keep it in the password manager that the installation administrators share.",
    own: "Keep it to yourself. Do not share it.",
    one_person: "Give it only to that person."
  }

  @doc """
  Every kind of secret, in the order of the inventory.

      iex> EhosPlatform.Secret.kinds() |> Enum.take(2)
      [:state_passphrase, :encrypted_state]
  """
  @spec kinds() :: [kind()]
  def kinds, do: Keyword.keys(@kinds)

  @doc """
  The label of `kind`, the label of its place in a command's values.

      iex> EhosPlatform.Secret.label(:kubeconfig)
      "Kubeconfig"
  """
  @spec label(kind()) :: String.t()
  def label(kind), do: kind |> entry() |> elem(0)

  @doc """
  What a leak or a loss of `kind` does, in one sentence: the head of its warning.

      iex> EhosPlatform.Secret.weight(:kubeconfig)
      "The kubeconfig gives administrator access to the cluster."
  """
  @spec weight(kind()) :: String.t()
  def weight(kind), do: kind |> entry() |> elem(1)

  @doc """
  Who keeps `kind`.

      iex> EhosPlatform.Secret.keeper(:state_passphrase)
      :shared
  """
  @spec keeper(kind()) :: keeper()
  def keeper(kind), do: kind |> entry() |> elem(2)

  @doc """
  The warning a person reads about `secret`, as a head and its explanation, or `nil` when the
  person has nothing to do: on a run that is not new for the secret, for one that ends with the
  session or that anyone may have, and for one the cluster keeps unless the run read it from a
  file.

      iex> %EhosPlatform.Secret{kind: :kubeconfig, place: "~/.ehos/office/kubeconfig", new?: true}
      ...> |> EhosPlatform.Secret.warning()
      {"The kubeconfig gives administrator access to the cluster.",
       "Keep it to yourself. Do not share it. Do not copy it: ehosctl server tunnel writes it again."}

      iex> %EhosPlatform.Secret{kind: :kubeconfig, place: "~/.ehos/office/kubeconfig"}
      ...> |> EhosPlatform.Secret.warning()
      nil
  """
  @spec warning(t()) :: {String.t(), String.t()} | nil
  # A value read from a file makes the run new for the secret, whatever `new?` says.
  def warning(%__MODULE__{new?: false, read_from: nil}), do: nil

  def warning(%__MODULE__{kind: kind, read_from: read_from}) do
    {_label, weight, keeper, note, section} = entry(kind)
    explanation(weight, keeper, note, section, read_from)
  end

  defp explanation(weight, :cluster, _note, _section, file) when is_binary(file),
    do:
      {weight,
       "The cluster now keeps a copy of the value in #{file}. The file is yours to keep or remove."}

  defp explanation(weight, keeper, note, section, _file) when is_map_key(@keepers, keeper) do
    sentences = Enum.reject([Map.fetch!(@keepers, keeper), note], &is_nil/1)
    {weight, Enum.join(sentences, " ") <> guide(section)}
  end

  defp explanation(_weight, _keeper, _note, _section, _file), do: nil

  defp guide(nil), do: ""
  defp guide(section), do: "\nHow: " <> section

  defp entry(kind), do: Keyword.fetch!(@kinds, kind)
end
