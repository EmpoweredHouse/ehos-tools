defmodule EhosPlatform.SecretTest do
  use ExUnit.Case, async: true

  alias EhosPlatform.Secret

  doctest Secret

  @share "https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#share-an-installation-with-another-installation-administrator"
  @openbao "https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#backing-up-and-restoring-openbao"

  test "has the kinds of secret of the inventory on ehos-tools#1013, each with a label, a weight and a keeper" do
    assert Secret.kinds() == [
             :state_passphrase,
             :encrypted_state,
             :ssh_key,
             :kubeconfig,
             :ca_key,
             :ca_certificate,
             :acme_account_key,
             :acme_dns_account,
             :pull_credential,
             :smtp_password,
             :openbao_key,
             :console_tls_key,
             :refresh_token,
             :cached_credentials,
             :printed_credential,
             :data_session_password,
             :invitation_link,
             :external_database_role,
             :application_secret,
             :trusted_ca
           ]

    for kind <- Secret.kinds() do
      assert Secret.label(kind) =~ ~r/^\S/
      assert Secret.weight(kind) =~ ~r/^[A-Z].*\.$/
      assert Secret.keeper(kind) in [:shared, :own, :one_person, :cluster, :none, :public]
    end
  end

  test "gives each kind the keeper of record T-30" do
    keepers = Map.new(Secret.kinds(), &{&1, Secret.keeper(&1)})

    assert keepers == %{
             state_passphrase: :shared,
             encrypted_state: :shared,
             ssh_key: :shared,
             openbao_key: :shared,
             kubeconfig: :own,
             refresh_token: :own,
             pull_credential: :own,
             invitation_link: :one_person,
             ca_key: :cluster,
             acme_account_key: :cluster,
             acme_dns_account: :cluster,
             smtp_password: :cluster,
             external_database_role: :cluster,
             console_tls_key: :cluster,
             application_secret: :cluster,
             data_session_password: :none,
             printed_credential: :none,
             cached_credentials: :none,
             ca_certificate: :public,
             trusted_ca: :public
           }
  end

  test "warns on a run new for a secret that a person keeps, with the keeper's sentence and the guide" do
    assert warning(:state_passphrase) ==
             {"Without the state passphrase, ehosctl cannot change or remove the server.",
              "Keep it in the password manager that the installation administrators share.\nHow: " <>
                @share}

    assert warning(:encrypted_state) ==
             {"Without a current copy of the state, ehosctl cannot change or remove the server.",
              "Keep it in the password manager that the installation administrators share. " <>
                "Copy it again after each ehosctl server up.\nHow: " <> @share}

    assert warning(:openbao_key) ==
             {"Without OpenBao's key, nobody can read the secret values in OpenBao or in its snapshots.",
              "Keep it in the password manager that the installation administrators share. " <>
                "Keep it in another place than the snapshots.\nHow: " <> @openbao}

    assert warning(:pull_credential) ==
             {"The cluster pulls the images of EHOS with your GitHub token until another person runs ehosctl install.",
              "Keep it to yourself. Do not share it. Each person with the kubeconfig can read the token."}

    assert warning(:invitation_link) ==
             {"The link is a password: it signs in as that person one time, within 15 minutes.",
              "Give it only to that person."}
  end

  test "warns on a value the cluster keeps only when the run read it from a file" do
    assert warning(:external_database_role) == nil

    assert Secret.warning(%Secret{
             kind: :smtp_password,
             place: "ehos-system/ehos-smtp",
             read_from: "smtp.password"
           }) ==
             {"With the SMTP password, a person can send mail as the installation.",
              "The cluster now keeps a copy of the value in smtp.password. The file is yours to keep or remove."}

    assert Secret.warning(%Secret{
             kind: :external_database_role,
             place: "ehos-data/ehos-external-ledger",
             new?: true,
             read_from: "ledger.password"
           }) ==
             {"With the password of the managing role, a person can manage that database.",
              "The cluster now keeps a copy of the value in ledger.password. The file is yours to keep or remove."}
  end

  test "does not warn on a secret that ends with its session, that anyone may have, or that the run did not change" do
    for kind <- [
          :data_session_password,
          :printed_credential,
          :cached_credentials,
          :ca_certificate,
          :trusted_ca
        ],
        do: assert(warning(kind) == nil)

    for kind <- Secret.kinds(),
        do: assert(Secret.warning(%Secret{kind: kind, place: "here"}) == nil)
  end

  defp warning(kind), do: Secret.warning(%Secret{kind: kind, place: "here", new?: true})
end
