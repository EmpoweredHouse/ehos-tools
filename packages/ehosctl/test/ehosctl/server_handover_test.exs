defmodule Ehosctl.ServerHandoverTest do
  # `ehosctl server handover` (ehos-tools#1105): what another installation administrator needs to
  # take an installation over, from what ehosctl knows of it. Not async: capture_io(:stderr)
  # captures stderr for every process.
  use Ehosctl.Case, async: false

  alias Ehosctl.Config
  alias Ehosctl.ServerHandover

  doctest ServerHandover

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    user_home = Path.join(dir, "user")
    stub_home(user_home)
    mock_op(false)

    %{
      opts: [home: Path.join(user_home, ".ehos"), config_dir: Path.join(dir, "config")],
      home: Path.join(user_home, ".ehos")
    }
  end

  test "prints the handover of a GCP installation under its own CA, for the person's email",
       %{opts: opts, home: home} do
    pem = gcp(home)

    {0, stdout, ""} =
      ehosctl(~w(server handover --installation acme --email ada@example.com), opts)

    assert stdout ==
             """
             ✓ The handover of the installation acme:
               Provider       Google Cloud, acme-ehos, europe-west3
               SSH key        ~/.ssh/ehos_acme
               Certificates   Its own CA, ~/.ehos/acme/ca.crt

             Does the person need to be an installation administrator?
             An installation administrator makes, changes and removes the server, and installs and upgrades EHOS.
             An installation administrator gets root on the server and administrator access to the cluster. You cannot take this access back yet.
             If the person only deploys applications, do not hand over the installation. Invite them as a person:
               ehosctl server tunnel --installation acme
               ehosctl server invite ada@example.com --installation acme
             Then give them the CA file, as the section about certificates says, and nothing else.

             Put these in the password manager that the installation administrators share
             State passphrase. Without the state passphrase, ehosctl cannot change or remove the server.
             Encrypted state, in a copy of ~/.ehos/acme. Without a current copy of the state, ehosctl cannot change or remove the server. Make the copy, without the files that ehosctl writes again:
               (umask 077; tar czf ehos-acme-$(date +%F).tgz -C ~/.ehos --exclude acme/tofu/providers --exclude 'acme/tunnel.*' --exclude acme/kubeconfig acme)
             Put the file in the password manager, then remove it from the disk. Make a new copy after each ehosctl server up.
               rm ehos-acme-$(date +%F).tgz
             SSH key, ~/.ssh/ehos_acme. The SSH key gives a shell on the server, as root.
             On Google Cloud, the person can make a key of their own instead. Their ehosctl server up --ssh-key puts it on the server in place of this key, which then stops working.

             Do not hand over OpenBao's key
             The person reads OpenBao's key from the cluster, with their kubeconfig.
             A copy outside the server is a backup for a lost server. Without OpenBao's key, nobody can read the secret values in OpenBao or in its snapshots.
             ehosctl has no record that it told you about this backup on this machine. If the backup does not exist, make it while the tunnel is open:
               ehosctl server tunnel --installation acme
               (umask 077; KUBECONFIG=~/.ehos/acme/kubeconfig kubectl -n ehos-system get secret ehos-openbao-seal -o jsonpath='{.data}' > openbao-seal-acme.json)
             Put the file in the password manager, apart from the snapshots of OpenBao. Then remove it from the disk.

             The person makes these for themselves
             A sign-in to Google Cloud with the role roles/compute.admin on the project acme-ehos. Do not give Owner or Editor. To give the role, run:
               gcloud projects add-iam-policy-binding acme-ehos --member=user:ada@example.com --role=roles/compute.admin
             Then the person signs in on their machine:
               gcloud auth application-default login
             Do not share your own access to the cloud account.
             A GitHub token that reads the releases of EHOS, as GITHUB_TOKEN.
             A classic GitHub token with read:packages only, as GHCR_TOKEN. The cluster pulls the images of EHOS with your GitHub token until another person runs ehosctl install.

             Let the person into EHOS
             Invite the person, and give them the role ehos.administrator on the whole platform:
               ehosctl server tunnel --installation acme
               ehosctl server invite ada@example.com --installation acme
               ehosctl role-bindings bind ehos.administrator --to ada@example.com --installation acme
             The link that ehosctl server invite prints is a password. Give it only to that person.

             Certificates
             The installation has its own CA, in ~/.ehos/acme/ca.crt. Anyone may have the certificate of the CA. Give the person the file.
             Send its SHA-256 fingerprint over another channel, so that the person can check the file: #{fingerprint(pem)}
             The person signs in with it:
               EHOSCTL_CA_FILE=ca.crt ehosctl login --installation acme https://ehos.acme.example

             Decide who owns the state
             OpenTofu keeps the state of the server in a file on the workstation that ran ehosctl server up. Two copies of the state diverge.
             An up or a down from an old copy can make a second server, or remove resources. Until the state is shared and locked, only its owner runs ehosctl server up and down.
             SSH admits only the addresses that the last up was given: 203.0.113.4/32. The owner gives the address of each administrator to each up. ADDRESS is the public IPv4 address of the person:
               ehosctl server up --installation acme --ssh-from 203.0.113.4/32 --ssh-from ADDRESS

             What the person runs on their machine
             Restore the copy of the installation. After this, the person owns the state:
               (umask 077; mkdir -p ~/.ehos && tar xzf FILE -C ~/.ehos)
             Admit their address on SSH, and write the kubeconfig again. KEY is the SSH key from the password manager, or a key of their own. ADDRESS is their public IPv4 address.
               ehosctl server up --installation acme --ssh-key KEY --ssh-from 203.0.113.4/32 --ssh-from ADDRESS
               ehosctl server tunnel --installation acme --ssh-key KEY
             Add the installation to ehosctl, with their own GHCR_TOKEN. VERSION is the version of EHOS that runs: ehosctl versions --installation acme shows it to you.
               ehosctl install --installation acme --version VERSION
               ehosctl login --installation acme
             On the server, ehosctl install changes only the token that the cluster pulls images with.

             Put the items in the password manager
             In 1Password, make a vault for the installation and share it with the person. Add the state passphrase as a Password item, and the copy as a Document.
             Import the SSH key in the 1Password app: New Item, SSH Key, Import a Key File. If you install the 1Password CLI, op, this command prints the commands.
             In Apple Passwords, make a shared group with the person in it. Add the state passphrase to the group as a password.
             Apple Passwords holds no files. Keep the copy of ~/.ehos/acme and the SSH key in another place that only the installation administrators can read.
             """
  end

  test "--json gives the facts and the sections, with 1Password's commands when op is on the path",
       %{opts: opts, home: home} do
    gcp(home)
    public_certificates(home)
    mock_op(true)

    {0, stdout, ""} = ehosctl(~w(server handover --installation acme --json), opts)
    json = JSON.decode!(stdout)

    assert Map.delete(json, "sections") == %{
             "installation" => "acme",
             "provider" => "gcp",
             "place" => %{"project" => "acme-ehos", "region" => "europe-west3"},
             "ssh_key" => "~/.ssh/ehos_acme",
             "ssh_from" => ["203.0.113.4/32"],
             "certificates" => %{"kind" => "public"},
             "host" => "ehos.acme.example",
             "email" => nil
           }

    assert Enum.map(json["sections"], & &1["id"]) ==
             ~w(administrator shared openbao their_own in_ehos certificates state receiver password_manager)

    assert section(json, "certificates") == [
             %{
               "text" =>
                 "The installation has certificates from Let's Encrypt. The person signs in " <>
                   "with no CA file:",
               "commands" => ["ehosctl login --installation acme https://ehos.acme.example"]
             }
           ]

    assert commands(json, "password_manager") == [
             "op vault create ehos-acme",
             "op item template get Password | jq '(.fields[] | select(.id == \"password\") | " <>
               ".value) = env.EHOS_STATE_PASSPHRASE' | op item create --vault ehos-acme " <>
               "--title 'ehos-acme state passphrase' -",
             "(umask 077; tar czf - -C ~/.ehos --exclude acme/tofu/providers --exclude " <>
               "'acme/tunnel.*' --exclude acme/kubeconfig acme) | op document create - --vault " <>
               "ehos-acme --title 'ehos-acme copy of the installation' --file-name " <>
               "ehos-acme-$(date +%F).tgz",
             "op vault user grant --vault ehos-acme --user EMAIL --permissions " <>
               "allow_viewing,allow_editing"
           ]

    assert commands(json, "receiver") |> hd() ==
             "(umask 077; mkdir -p ~/.ehos && op document get 'ehos-acme copy of the " <>
               "installation' --vault ehos-acme | tar xzf - -C ~/.ehos)"
  end

  test "on AWS, says to share the SSH key, and gives the person's own profile to their commands",
       %{opts: opts, home: home} do
    installation(home, "shop", %{
      "provider" => "aws",
      "aws_account_id" => "123456789012",
      "region" => "eu-central-1",
      "aws_profile" => "shop"
    })

    {0, stdout, ""} = ehosctl(~w(server handover --installation shop), opts)

    assert stdout |> String.split("\n") |> Enum.take(6) == [
             "✓ The handover of the installation shop:",
             "  Provider       AWS, 123456789012, eu-central-1",
             "  SSH key        ~/.ssh/ehos_oci",
             "  Certificates   None: EHOS is not installed yet",
             "Give --email to put the email of the person in place of EMAIL.",
             ""
           ]

    {:ok, facts} = ServerHandover.facts("shop", opts)
    sections = Map.new(ServerHandover.sections(facts), &{&1.id, &1.parts})

    assert Enum.take(sections.shared, -2) == [
             {"SSH key, ~/.ssh/ehos_oci. The SSH key gives a shell on the server, as root.", []},
             {"On AWS, a new key makes the server again, and its databases are lost. Share " <>
                "this key.", []}
           ]

    assert hd(sections.their_own) ==
             {"An AWS profile of their own in the account 123456789012, with access to EC2 in " <>
                "eu-central-1. Do not give them your profile or the administrator of the " <>
                "account.", []}

    assert sections.certificates == [
             {"EHOS is not installed yet, so the installation has no certificate to give. Run " <>
                "this command again after ehosctl install.", []}
           ]

    assert Enum.at(sections.state, 2) ==
             {"SSH admits only the addresses that the last up was given: ehosctl has no record " <>
                "of them. The owner gives the address of each administrator to each up. ADDRESS " <>
                "is the public IPv4 address of the person:",
              ["ehosctl server up --installation shop --ssh-from ADDRESS"]}

    assert Enum.at(sections.receiver, 1) ==
             {"Admit their address on SSH, and write the kubeconfig again. KEY is the SSH key " <>
                "from the password manager. ADDRESS is their public IPv4 address. PROFILE is " <>
                "their own AWS profile.",
              [
                "ehosctl server up --installation shop --aws-profile PROFILE --ssh-key KEY " <>
                  "--ssh-from ADDRESS",
                "ehosctl server tunnel --installation shop --aws-profile PROFILE --ssh-key KEY"
              ]}
  end

  test "asks to check OpenBao's backup when ehosctl install warned of the key on this machine",
       %{opts: opts, home: home} do
    gcp(home)

    :ok =
      Config.write(
        Config.put_warned(
          Config.put(%Config{}, "acme", "https://ehos.acme.example"),
          "acme",
          :openbao_key
        ),
        opts[:config_dir]
      )

    {:ok, facts} = ServerHandover.facts("acme", opts)

    assert Enum.find(ServerHandover.sections(facts), &(&1.id == :openbao)).parts |> List.last() ==
             {"ehosctl install told you on this machine to keep this backup. Make sure that the " <>
                "password manager holds it, apart from the snapshots of OpenBao.", []}
  end

  test "every command it prints can be pasted, for each provider and each kind of certificate",
       %{opts: opts, home: home} do
    gcp(home)

    for provider <- ~w(gcp aws oci ovh),
        certificates <- [:public, {:own, "~/.ehos/acme/ca.crt", "AB:CD"}, :none],
        op? <- [true, false],
        email <- [nil, "o'hara@example.com"] do
      {:ok, facts} = ServerHandover.facts("acme", opts)
      {:ok, parsed} = EhosPlatform.Server.Provider.parse(provider)

      facts = %{
        facts
        | provider: parsed,
          certificates: certificates,
          op?: op?,
          email: email,
          host: nil
      }

      for section <- ServerHandover.sections(facts), {_text, commands} <- section.parts do
        for command <- commands,
            do: assert(Ehosctl.Output.pastable?(command), "not pastable: #{command}")
      end
    end
  end

  test "refuses an --email EHOS does not take, before it reads the installation", %{opts: opts} do
    assert ehosctl(["server", "handover", "--email", "ada@example.com,alan@example.com"], opts) ==
             {2, "",
              ~s|ehosctl: --email: "ada@example.com,alan@example.com" is not an email address | <>
                "EHOS takes: one @ with something on each side, and no space, comma or " <>
                "semicolon. ehosctl printed nothing.\n"}
  end

  test "refuses an installation with no server on this machine, as the server's commands do",
       %{opts: opts} do
    assert {1, "", "ehosctl: This computer has no server for the installation acme" <> _rest} =
             ehosctl(~w(server handover --installation acme), opts)
  end

  test "names the file it cannot read", %{opts: opts, home: home} do
    gcp(home)
    File.write!(Path.join([home, "acme", "install.json"]), "[]")

    assert ehosctl(~w(server handover --installation acme), opts) ==
             {1, "",
              "ehosctl: ehosctl cannot read #{home}/acme/install.json: it is not a JSON object. " <>
                "Restore it from the copy of the installation in the password manager. ehosctl " <>
                "printed nothing.\n"}
  end

  # A GCP installation with its own CA, installed, with one block admitted on SSH; the CA's PEM.
  defp gcp(home) do
    installation(home, "acme", %{
      "provider" => "gcp",
      "project" => "acme-ehos",
      "region" => "europe-west3",
      "ssh_key" => "~/.ssh/ehos_acme"
    })

    dir = Path.join(home, "acme")
    File.write!(Path.join(dir, "server.tfvars.json"), ~s({"ssh_from": ["203.0.113.4/32"]}))
    File.write!(Path.join(dir, "install.json"), ~s({"host": "ehos.acme.example"}))
    pem = Ehosctl.TestCA.certificate("acme CA", {:namedCurve, :secp256r1})
    File.write!(Path.join(dir, "ca.crt"), pem)
    pem
  end

  defp public_certificates(home),
    do: File.cp!(EhosPlatform.PublicCertificates.roots(), Path.join([home, "acme", "ca.crt"]))

  defp installation(home, name, place) do
    dir = Path.join(home, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "installation.json"), JSON.encode!(place))

    unless File.exists?(Path.join(dir, "server.tfvars.json")),
      do: File.write!(Path.join(dir, "server.tfvars.json"), "{}")
  end

  # As `openssl x509 -noout -fingerprint -sha256` prints it.
  defp fingerprint(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)

    :crypto.hash(:sha256, der)
    |> Base.encode16()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.join(":")
  end

  defp section(json, id), do: Enum.find(json["sections"], &(&1["id"] == id))["parts"]

  defp commands(json, id), do: json |> section(id) |> Enum.flat_map(& &1["commands"])

  defp mock_op(present?) do
    Hammox.stub(Ehosctl.OSMock, :find_executable, fn
      "op" -> if present?, do: "/usr/local/bin/op"
      name -> System.find_executable(name)
    end)
  end
end
