defmodule Ehosctl.Db do
  @moduledoc """
  `ehosctl db`: a person's data sessions, a time-limited way into one application's database in
  one environment (eh-os
  [D-149](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0149-a-person-s-database-session-reaches-its-instance-through-a-data-gateway-of-its-own-not-the-governance-plane.md),
  [D-171](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0171-a-person-s-database-session-gets-a-role-that-is-made-as-its-binding-s-roles-are-a-member-of-its-schema-s-read-or-write-group-with-a-password-only-the-person-s-client-knows-and-openbao-makes-none.md)).

  `db trust-ca FINGERPRINT` takes the data CA or the gateway CA that the installation gives now,
  when its fingerprint is the one the person typed: the one way a CA with a new key replaces the
  one `ehosctl` keeps (`Ehosctl.DataCa`). The fingerprint comes from the installation's
  administrator, outside EHOS, so a governance plane taken over cannot give it.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Config
  alias Ehosctl.DataCa
  alias Ehosctl.Output

  @impl Ehosctl.Command
  def name, do: :db

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec do
    [
      about: "Open, list and end your data sessions, and trust the CAs that they use.",
      subcommands: [
        trust_ca: [
          name: "trust-ca",
          about:
            "Trust the new data CA or gateway CA of the installation. Give the fingerprint " <>
              "that the administrator of the installation gave you.",
          args: [
            fingerprint: [
              value_name: "FINGERPRINT",
              required: true,
              help:
                "The SHA-256 of the key of the CA, in base64, or in hexadecimal with or " <>
                  "without colons."
            ]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]
  end

  @doc "Runs the subcommand in `path`, for the installation in `opts[:installation]`."
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:trust_ca], %{args: %{fingerprint: typed}}, opts) do
    {name, _installation} = installation = Keyword.fetch!(opts, :installation)

    with :ok <- kept_here(installation),
         {:ok, fingerprint} <- fingerprint(typed),
         {:ok, offered} <- DataCa.offered(installation, opts),
         {:ok, kind, ca} <- matching(offered, fingerprint, name),
         before = before(installation, kind),
         {:ok, _read, _written} <-
           Config.update(config_dir(opts), &{:ok, Config.put_data_ca(&1, name, kind, ca)}) do
      {:ok, trusted(name, kind, fingerprint, before)}
    end
  end

  # `EHOSCTL_URL` names an installation that no `config.json` keeps (T-18).
  defp kept_here(installation) do
    if Config.from_url?(installation),
      do:
        {:error, :invalid,
         "EHOSCTL_URL names an installation that ehosctl keeps nothing for. Run " <>
           "`ehosctl login URL` with the address of the installation."},
      else: :ok
  end

  defp fingerprint(typed) do
    case DataCa.typed(typed) do
      {:ok, fingerprint} ->
        {:ok, fingerprint}

      :error ->
        {:error, :invalid,
         "#{inspect(typed)} is not a fingerprint. A fingerprint is a SHA-256 in base64, such " <>
           "as qUiQTy8PR5uPgZdpSzAYSw0u0cHNKh7A+4XSmaGSpEc=, or in hexadecimal."}
    end
  end

  defp matching(offered, fingerprint, name) do
    found =
      Enum.find(DataCa.kinds(), fn kind ->
        match?(%{key_sha256: ^fingerprint}, offered[kind])
      end)

    if found,
      do: {:ok, found, offered[found]},
      else:
        {:error, :failed,
         "Neither the data CA nor the gateway CA that #{name} gives has the fingerprint " <>
           "#{fingerprint}. ehosctl trusts nothing new. Check the fingerprint with the " <>
           "administrator of the installation."}
  end

  # A kept CA `ehosctl` cannot read is replaced too: this is how the person mends it.
  defp before(installation, kind) do
    case DataCa.kept(installation, kind) do
      {:ok, kept} -> kept
      {:error, _kind, _message} -> nil
    end
  end

  defp trusted(name, kind, fingerprint, before) do
    already? = match?(%{key_sha256: ^fingerprint}, before)

    text =
      if already?,
        do: "ehosctl already trusts the #{DataCa.label(kind)} of #{name} with this fingerprint.",
        else: "ehosctl now trusts the #{DataCa.label(kind)} of #{name} with this fingerprint."

    %{
      text: text,
      json: %{installation: name, ca: kind, key_sha256: fingerprint, changed: not already?}
    }
  end

  defp config_dir(opts), do: Keyword.get_lazy(opts, :config_dir, &Config.dir/0)
end
