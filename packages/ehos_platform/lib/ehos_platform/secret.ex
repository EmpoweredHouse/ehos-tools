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
          | :shared_ssh_key
          | :kubeconfig
          | :k3s_kubeconfig
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

  # Each kind: its label, its weight, its keeper, and, where it has them, a sentence of its own
  # after the keeper's (`note`) and the section of the installation guide with the procedure
  # (`guide`).
  @kinds [
    state_passphrase: %{
      label: "State passphrase",
      weight: "Without the state passphrase, ehosctl cannot change or remove the server.",
      keeper: :shared,
      guide: @share
    },
    encrypted_state: %{
      label: "Encrypted state",
      weight: "Without a current copy of the state, ehosctl cannot change or remove the server.",
      keeper: :shared,
      note: "Copy it again after each ehosctl server up.",
      guide: @share
    },
    # eh-os D-199: each installation administrator has an SSH key and a client certificate of
    # their own; the shared key and k3s's admin file are what an installation not moved yet holds.
    ssh_key: %{
      label: "SSH key",
      weight: "The SSH key gives a shell on the server, as root.",
      keeper: :own,
      note:
        "Each installation administrator has a key of their own, which another one adds with ehosctl server admin add.",
      guide: @share
    },
    shared_ssh_key: %{
      label: "Shared SSH key",
      weight:
        "The shared SSH key gives a shell on the server, as root, to each person who holds it.",
      keeper: :shared,
      note:
        "Move to keys of your own: ehosctl server admin add for each person, then ehosctl server admin remove shared.",
      guide: @share
    },
    kubeconfig: %{
      label: "Kubeconfig",
      weight:
        "The kubeconfig gives administrator access to the cluster until its certificate expires, within 12 hours.",
      keeper: :own,
      note: "Do not copy it: ehosctl server tunnel writes it again."
    },
    k3s_kubeconfig: %{
      label: "Kubeconfig of k3s",
      weight:
        "The kubeconfig holds the administrator certificate of k3s, which works for a year and which nobody can revoke.",
      keeper: :own,
      note:
        "Each person who ran ehosctl server tunnel without an installation administrator of their own holds the same certificate."
    },
    ca_key: %{
      label: "CA key",
      weight:
        "With the key of the installation's CA, a person can make certificates that ehosctl and pipelines trust.",
      keeper: :cluster
    },
    ca_certificate: %{
      label: "CA",
      weight: "Anyone may have the certificate of the CA.",
      keeper: :public
    },
    acme_account_key: %{
      label: "Let's Encrypt account key",
      weight:
        "With a Let's Encrypt account key, a person can get certificates for the console's addresses.",
      keeper: :cluster
    },
    acme_dns_account: %{
      label: "acme-dns account",
      weight:
        "With the acme-dns account, a person can answer the DNS challenge of the installation's domain.",
      keeper: :cluster
    },
    pull_credential: %{
      label: "Pull credential",
      weight:
        "The cluster pulls the images of EHOS with your GitHub token until another person runs ehosctl install.",
      keeper: :own,
      note: "Each person with the kubeconfig can read the token."
    },
    smtp_password: %{
      label: "SMTP password",
      weight: "With the SMTP password, a person can send mail as the installation.",
      keeper: :cluster
    },
    openbao_key: %{
      label: "OpenBao's key",
      weight:
        "Without OpenBao's key, nobody can read the secret values in OpenBao or in its snapshots.",
      keeper: :shared,
      note: "Keep it in another place than the snapshots.",
      guide: @openbao
    },
    console_tls_key: %{
      label: "Console TLS key",
      weight: "With the TLS key of the console, a person can answer as the console.",
      keeper: :cluster
    },
    refresh_token: %{
      label: "Sign-in",
      weight:
        "With the refresh token, a person acts as you until it expires or you run ehosctl logout.",
      keeper: :own
    },
    cached_credentials: %{
      label: "Cached credentials",
      weight: "With a cached credential, a person acts as you for up to 10 minutes.",
      keeper: :none
    },
    printed_credential: %{
      label: "Credential",
      weight: "With the credential, a person acts as you for up to 10 minutes.",
      keeper: :none
    },
    data_session_password: %{
      label: "Password",
      weight:
        "With the password, a person reads the data of the application until the session ends.",
      keeper: :none
    },
    invitation_link: %{
      label: "Link",
      weight: "The link is a password: it signs in as that person one time, within 15 minutes.",
      keeper: :one_person
    },
    external_database_role: %{
      label: "Managing role",
      weight: "With the password of the managing role, a person can manage that database.",
      keeper: :cluster
    },
    application_secret: %{
      label: "Application secret",
      weight:
        "With the value of the secret, a person has the access that the secret gives to the application.",
      keeper: :cluster
    },
    trusted_ca: %{
      label: "Trusted CA",
      weight: "Anyone may have the certificate of a CA.",
      keeper: :public
    }
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
  def label(kind), do: entry(kind).label

  @doc """
  What a leak or a loss of `kind` does, in one sentence: the head of its warning.

      iex> EhosPlatform.Secret.weight(:kubeconfig)
      "The kubeconfig gives administrator access to the cluster until its certificate expires, within 12 hours."
  """
  @spec weight(kind()) :: String.t()
  def weight(kind), do: entry(kind).weight

  @doc """
  Who keeps `kind`.

      iex> EhosPlatform.Secret.keeper(:state_passphrase)
      :shared
  """
  @spec keeper(kind()) :: keeper()
  def keeper(kind), do: entry(kind).keeper

  @doc """
  The warning a person reads about `secret`, as a head and its explanation, or `nil` when the
  person has nothing to do: on a run that is not new for the secret, for one that ends with the
  session or that anyone may have, and for one the cluster keeps unless the run read it from a
  file.

      iex> %EhosPlatform.Secret{kind: :kubeconfig, place: "~/.ehos/office/kubeconfig", new?: true}
      ...> |> EhosPlatform.Secret.warning()
      {"The kubeconfig gives administrator access to the cluster until its certificate expires, within 12 hours.",
       "Keep it to yourself. Do not share it. Do not copy it: ehosctl server tunnel writes it again."}

      iex> %EhosPlatform.Secret{kind: :kubeconfig, place: "~/.ehos/office/kubeconfig"}
      ...> |> EhosPlatform.Secret.warning()
      nil
  """
  @spec warning(t()) :: {String.t(), String.t()} | nil
  def warning(%__MODULE__{kind: kind, read_from: read_from} = secret) do
    if new?(secret), do: explanation(entry(kind), read_from)
  end

  @doc """
  Whether the run is new for `secret`: it says so, or it read the value from a file.

      iex> EhosPlatform.Secret.new?(%EhosPlatform.Secret{kind: :smtp_password, place: "ehos-system/ehos-smtp", read_from: "smtp.password"})
      true
  """
  @spec new?(t()) :: boolean()
  def new?(%__MODULE__{new?: new?, read_from: read_from}), do: new? or is_binary(read_from)

  defp explanation(%{keeper: :cluster} = entry, file) when is_binary(file),
    do:
      {entry.weight,
       "The cluster now keeps a copy of the value from #{file}. The file is yours to keep or remove."}

  defp explanation(%{keeper: keeper} = entry, _file) when is_map_key(@keepers, keeper) do
    sentences = Enum.reject([Map.fetch!(@keepers, keeper), entry[:note]], &is_nil/1)
    {entry.weight, Enum.join(sentences, " ") <> guide(entry[:guide])}
  end

  defp explanation(_entry, _file), do: nil

  defp guide(nil), do: ""
  defp guide(section), do: "\nThe installation guide says how: " <> section

  defp entry(kind), do: Keyword.fetch!(@kinds, kind)
end
