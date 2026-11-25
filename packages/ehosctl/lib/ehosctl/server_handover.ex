defmodule Ehosctl.ServerHandover do
  @moduledoc """
  `ehosctl server handover --installation NAME`: prints, for one installation, what another
  installation administrator needs to take it over, where each thing is, what that person makes
  for themselves, and the commands each of them runs. It is the procedure of eh-os's installation
  guide ("Share an installation with another installation administrator") filled in with what
  ehosctl knows of the installation. Nobody hands over an SSH key or a kubeconfig: the person makes
  a key of their own, which the giver adds with `ehosctl server admin add`, and their `tunnel`
  gets a certificate of their own (eh-os D-199).

  It runs under `ehosctl server` (`c:Ehosctl.Command.mounted/0`), on the local plane: it reads the
  installation's files in `~/.ehos/<name>/` and ehosctl's configuration, and contacts nothing,
  writes nothing and reads no secret's value. What it says is built as data first, `facts/2` and
  then `sections/1`, whose commands `pasted/1` filters once for the words and `--json` (T-28). The secrets it names are
  described with `EhosPlatform.Secret`'s words (T-30); OpenBao's key is not one it hands over,
  since the person reads it from the cluster, and the copy outside the server is a backup.
  """

  @behaviour Ehosctl.Command

  require Record

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  alias Ehosctl.Config
  alias Ehosctl.Output
  alias EhosPlatform.Secret
  alias EhosPlatform.Server, as: Platform
  alias EhosPlatform.Server.Provider
  alias EhosPlatform.Shell

  # jq puts the passphrase from the environment in the template's password field, and stops on a
  # variable that is not set or is empty.
  @passphrase_filter ~S{'(.fields[] | select(.id == "password") | .value) = } <>
                       ~S{(env.EHOS_STATE_PASSPHRASE // "" | if . == "" then } <>
                       ~S{error("EHOS_STATE_PASSPHRASE is not set") else . end)'}

  @enforce_keys [
    :name,
    :provider,
    :place,
    :home,
    :ssh_key,
    :ssh_from,
    :administrator,
    :oci_profile,
    :certificates,
    :host,
    :email,
    :op?,
    :openbao_warned?
  ]
  defstruct @enforce_keys

  @typedoc """
  The installation's certificates: from Let's Encrypt, from its own CA (with the CA file's path
  and its SHA-256 fingerprint, `nil` when the file holds no certificate), or none yet.
  """
  @type certificates :: :public | {:own, Path.t(), String.t() | nil} | :none

  @typedoc """
  What ehosctl knows of the installation for a handover:

    * `place`, what `installation.json` records of where the server is: the region and the
      account (`project` on GCP, `aws_account_id`, `tenancy_ocid`, `project_id` on OVHcloud);
    * `home`, where the installations are kept, as a person types it (`~/.ehos`);
    * `ssh_key`, the private key `up` recorded, as it is recorded;
    * `ssh_from`, the blocks the last `up` admitted SSH from;
    * `administrator`, the installation administrator this workstation acts as (eh-os D-199), or
      `nil` on an installation that has none of their own yet;
    * `oci_profile`, the profile of `~/.oci/config` that `up` reads on Oracle, `DEFAULT` unless
      `up` recorded another;
    * `host`, the console's host, from `install.json`, or `nil`;
    * `email`, the person's, or `nil`;
    * `op?`, whether 1Password's CLI is on the path;
    * `openbao_warned?`, whether `ehosctl install` warned of OpenBao's key on this machine.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          provider: Provider.t(),
          place: %{String.t() => String.t()},
          home: String.t(),
          ssh_key: String.t(),
          ssh_from: [String.t()],
          administrator: String.t() | nil,
          oci_profile: String.t(),
          certificates: certificates(),
          host: String.t() | nil,
          email: String.t() | nil,
          op?: boolean(),
          openbao_warned?: boolean()
        }

  @typedoc """
  One section of the handover: its id, its title, and its parts, each a sentence and the
  commands that follow it, possibly none.
  """
  @type section :: %{
          id: atom(),
          title: String.t(),
          parts: [{String.t(), [String.t()]}]
        }

  @impl Ehosctl.Command
  def name, do: :handover

  @impl Ehosctl.Command
  def plane, do: :local

  @impl Ehosctl.Command
  def group, do: :installation

  @impl Ehosctl.Command
  def summary, do: "Print what to give another installation administrator, and how."

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Print what another installation administrator needs to take over the installation, " <>
          "and the commands that each of you runs. ehosctl contacts nothing, changes nothing " <>
          "and shows no secret.",
      options: [
        installation: [
          long: "--installation",
          value_name: "NAME",
          help:
            "The installation to hand over. By default EHOSCTL_INSTALLATION, else the current " <>
              "installation, else trial."
        ],
        email: [
          long: "--email",
          value_name: "EMAIL",
          help:
            "The email of the person who takes over. If you do not give it, the commands say " <>
              "EMAIL in its place."
        ]
      ],
      flags: Output.json_flag()
    ]

  @doc """
  Prints the handover of the installation `--installation` names, or of the one
  `Ehosctl.Server.installation/3` comes to, which must have a server on this machine. `opts` may
  name `:home` and `:config_dir`, as for `Ehosctl.Server`.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    with {:ok, email} <- email(parsed.options[:email]),
         {:ok, name} <- Ehosctl.Server.installation(parsed.options[:installation], opts),
         {:ok, facts} <- facts(name, Keyword.put(opts, :email, email)) do
      sections = facts |> sections() |> pasted()
      {:ok, %{text: text(facts, sections), json: json(facts, sections)}}
    end
  end

  @doc """
  What ehosctl knows of the installation `name` for its handover, read from its files under
  `opts[:home]` (`~/.ehos`) and from the configuration in `opts[:config_dir]`, with the person's
  `opts[:email]`. A record that cannot be read is a failure, which names the file.
  """
  @spec facts(String.t(), keyword()) :: {:ok, t()} | {:error, Output.kind(), String.t()}
  def facts(name, opts) do
    home = Ehosctl.Server.home(opts)
    dir = Path.join(home, name)

    with {:ok, place} <- recorded(dir, "installation.json"),
         {:ok, vars} <- recorded(dir, "server.tfvars.json"),
         {:ok, installed} <- recorded(dir, "install.json"),
         {:ok, provider} <- provider(place, dir),
         user_home = Ehosctl.OS.current().home(),
         {:ok, certificates} <- certificates(dir, user_home) do
      {:ok,
       %__MODULE__{
         name: name,
         provider: provider,
         place: place |> Map.take(Provider.identity(provider)) |> Map.filter(&string?/1),
         home: Platform.portable_path(home, user_home),
         ssh_key: string(place["ssh_key"]) || Platform.default_key(),
         ssh_from: Enum.filter(List.wrap(vars["ssh_from"]), &is_binary/1),
         administrator: printable(place["administrator"]),
         oci_profile: printable(place["oci_profile"]) || "DEFAULT",
         certificates: certificates,
         host: printable(installed["host"]),
         email: opts[:email],
         op?: Ehosctl.OS.current().find_executable("op") != nil,
         openbao_warned?: openbao_warned?(name, opts)
       }}
    end
  end

  @doc """
  The SHA-256 fingerprint of the first certificate in `pem`, as `openssl x509 -noout -fingerprint
  -sha256` prints it, or `nil` when `pem` holds none.

      iex> Ehosctl.ServerHandover.fingerprint("no certificate")
      nil
  """
  @spec fingerprint(binary()) :: String.t() | nil
  def fingerprint(pem) do
    case for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der) do
      [der | _rest] -> colons(:crypto.hash(:sha256, der))
      [] -> nil
    end
  end

  defp colons(digest),
    do: digest |> Base.encode16() |> String.graphemes() |> Enum.chunk_every(2) |> Enum.join(":")

  @doc """
  The sections of the handover of `facts`, in the order a person reads them: first if the person
  needs to be an installation administrator at all, last the password manager's own steps.

  Each command is as it was built, which `pasted/1` filters before it is printed.
  """
  @spec sections(t()) :: [section()]
  def sections(%__MODULE__{} = facts) do
    [
      administrator(facts),
      shared(facts),
      add(facts),
      openbao(facts),
      their_own(facts),
      in_ehos(facts),
      certificates_section(facts),
      state(facts),
      receiver(facts),
      password_manager(facts)
    ]
  end

  @doc """
  `sections` without each command that is not `Ehosctl.Output.pastable?/1`, as one with a value
  from a file that holds a `\\`: the words and `--json` print these, so they offer the same
  commands, and the sentence of a command left out stays.
  """
  @spec pasted([section()]) :: [section()]
  def pasted(sections) do
    Enum.map(sections, fn section ->
      Map.update!(section, :parts, &Enum.map(&1, fn part -> pasted_part(part) end))
    end)
  end

  defp pasted_part({sentence, commands}),
    do: {sentence, Enum.filter(commands, &Output.pastable?/1)}

  defp administrator(facts) do
    n = word(facts.name)

    %{
      id: :administrator,
      title: "Does the person need to be an installation administrator?",
      parts: [
        say(
          "An installation administrator makes, changes and removes the server, and installs " <>
            "and upgrades EHOS."
        ),
        say(
          "An installation administrator gets root on the server and administrator access to " <>
            "the cluster. ehosctl server admin remove takes back their own key, and takes their " <>
            "user out of each binding. It does not take back the key that every administrator shared, " <>
            "while the server has it, their copy of the state, or access that they made."
        ),
        run(
          "If the person only deploys applications, do not hand over the installation. Invite " <>
            "them as a person:",
          [
            "ehosctl server tunnel --installation #{n}",
            "ehosctl server invite #{who(facts)} --installation #{n}"
          ]
        ),
        say(only_ca(facts.certificates))
      ]
    }
  end

  defp only_ca({:own, _path, _fingerprint}),
    do: "Then give them the CA file, as the section about certificates says, and nothing else."

  defp only_ca(_public_or_none), do: "Give them nothing else."

  defp shared(facts) do
    %{
      id: :shared,
      title: "Put these in the password manager that the installation administrators share",
      parts: [
        say("#{Secret.label(:state_passphrase)}. #{Secret.weight(:state_passphrase)}")
        | copy(facts)
      ]
    }
  end

  defp copy(%{op?: true} = facts),
    do: [
      say(
        "#{copy_label(facts)} #{Secret.weight(:encrypted_state)} The section about the " <>
          "password manager has the commands."
      )
    ]

  defp copy(facts),
    do: [
      run(
        "#{copy_label(facts)} #{Secret.weight(:encrypted_state)} Make the copy, without the " <>
          "files that ehosctl writes again:",
        ["(umask 077; rm -f #{archive(facts)} && tar czf #{archive(facts)} #{tar_args(facts)})"]
      ),
      say(not_whole()),
      run(
        "Put the file in the password manager, then remove it from the disk. Make a new copy " <>
          "after each ehosctl server up.",
        ["rm #{archive(facts)}"]
      )
    ]

  defp copy_label(facts),
    do: "#{Secret.label(:encrypted_state)}, in a copy of #{facts.home}/#{facts.name}."

  # The file on the disk has no date, so the `rm` after it names it on any day; the copy in
  # 1Password has one.
  defp archive(facts), do: "ehos-#{facts.name}.tgz"
  defp dated_archive(facts), do: "ehos-#{facts.name}-$(date +%F).tgz"

  # tar's errors scroll past before the next step, so what one means is said here.
  defp not_whole, do: "If tar prints an error, the copy is not whole. Make it again."

  # The copy goes to 1Password only once tar has written it whole, from a file of mktemp's,
  # which only its owner reads, and which the command removes whatever happened.
  # The traps remove the file on an interrupt too: dash runs an EXIT trap on no signal, so a
  # signal exits the subshell first.
  defp staged(facts, op),
    do:
      "(umask 077; f=$(mktemp) && trap 'rm -f #{tar_file()}' EXIT && trap 'exit 130' INT TERM " <>
        "HUP && tar czf #{tar_file()} #{tar_args(facts)} && #{op} --file-name " <>
        "#{dated_archive(facts)})"

  defp tar_file, do: ~S("$f")

  # The guide's exclusions: the provider's program for this workstation, the tunnel's files and
  # the kubeconfig, which the next commands write again.
  defp tar_args(facts) do
    n = facts.name

    "-C #{shell_path(facts.home)} --exclude #{word(n <> "/tofu/providers")} " <>
      "--exclude #{word(n <> "/tunnel.*")} --exclude #{word(n <> "/kubeconfig")} #{word(n)}"
  end

  # eh-os D-199: the person gets an SSH key of their own, which the giver adds; nobody hands over
  # a key. A giver with no access of their own yet adds themself first.
  defp add(facts) do
    n = word(facts.name)
    key = own_key(facts)
    you = facts.administrator || "YOUR_NAME"

    %{
      id: :add,
      title: "Add the person to the server",
      parts:
        yourself(facts, key) ++
          [
            run(
              "The person makes an SSH key of their own on their machine, and sends you its " <>
                ".pub file. The private key stays on their machine:",
              ["ssh-keygen -t ed25519 -f #{key}"]
            ),
            run(
              "Add the person. NAME is their name as an installation administrator: 1 to 31 " <>
                "lowercase letters, digits and hyphens. FILE is their .pub file. Compare the " <>
                "fingerprint that ehosctl prints with the one that ssh-keygen -l -f prints on " <>
                "their machine:",
              ["ehosctl server admin add NAME --public-key FILE --installation #{n}"]
            )
          ] ++ leaving(facts, key, you)
    }
  end

  # On GCP, the guest agent writes the metadata's key back, so `admin remove` refuses the person
  # whose key it is until `up --provisioning-key` moves it (eh-os D-199).
  defp leaving(%{provider: :gcp} = facts, key, you) do
    n = word(facts.name)

    [
      run(
        "If you leave the installation, the person removes your access after they take it over. " <>
          "On Google Cloud, the metadata of the server can hold your key, which comes back after " <>
          "a removal: the person first puts their own key there. ADDRESS is their public IPv4 " <>
          "address, so that SSH still admits them. Each up replaces the addresses that SSH " <>
          "admits: before this step, the person runs ehosctl server handover again on their " <>
          "machine, and uses the up that it gives:",
        [
          "ehosctl server up --installation #{n} --ssh-key #{key} --provisioning-key #{key}.pub" <>
            kept(facts) <> " --ssh-from ADDRESS",
          "ehosctl server admin remove #{word(you)} --installation #{n}"
        ]
      ),
      shared_key(facts)
    ]
  end

  defp leaving(facts, _key, you),
    do: [
      run(
        "If you leave the installation, the person removes your access after they take it over:",
        ["ehosctl server admin remove #{word(you)} --installation #{facts.name |> word()}"]
      ),
      shared_key(facts)
    ]

  # Removing a person takes away their own line, not the key that every administrator shared
  # before eh-os D-199, which logs in whoever holds it until it goes.
  defp shared_key(facts),
    do:
      run(
        "If the server still has the key that every administrator shared, removing you does not " <>
          "take it away. Once each administrator has a key of their own, the person removes it:",
        ["ehosctl server admin remove shared --installation #{word(facts.name)}"]
      )

  defp yourself(%{administrator: nil} = facts, key) do
    n = word(facts.name)

    [
      run(
        "You have no access of your own to the server yet. Add yourself first, with a new key. " <>
          "YOUR_NAME is your name as an installation administrator:",
        [
          "ssh-keygen -t ed25519 -f #{key}",
          "ehosctl server admin add YOUR_NAME --public-key #{key}.pub --installation #{n}",
          "ehosctl server tunnel --installation #{n} --ssh-key #{key} --administrator YOUR_NAME"
        ]
      )
    ]
  end

  defp yourself(_facts, _key), do: []

  # Not ~/.ssh/ehos_<name>, where the key every administrator shared often is: ssh-keygen would
  # offer to write over it.
  defp own_key(facts), do: "~/.ssh/" <> word("ehos_#{facts.name}_admin")

  defp openbao(facts) do
    %{
      id: :openbao,
      title: "Do not hand over OpenBao's key",
      parts: [
        say("The person reads OpenBao's key from the cluster, with their kubeconfig."),
        say(
          "A copy outside the server is a backup for a lost server. " <>
            Secret.weight(:openbao_key)
        )
        | backup(facts)
      ]
    }
  end

  defp backup(%{openbao_warned?: true}),
    do: [
      say(
        "ehosctl install told you on this machine to keep this backup. Make sure that the " <>
          "password manager holds it, apart from the snapshots of OpenBao."
      )
    ]

  defp backup(facts) do
    n = facts.name

    [
      run(
        "ehosctl has no record that it told you about this backup on this machine. If the " <>
          "backup does not exist, make it while the tunnel is open:",
        [
          "ehosctl server tunnel --installation #{word(n)}",
          "(umask 077; set -C; seal=$(KUBECONFIG=#{shell_path("#{facts.home}/#{n}/kubeconfig")} " <>
            "kubectl -n ehos-system get secret ehos-openbao-seal -o jsonpath='{.data}') && " <>
            ~S(printf '%s' "$seal" > ) <> "#{word("openbao-seal-#{n}.json")})"
        ]
      ),
      say(
        "Put the file in the password manager, apart from the snapshots of OpenBao. Then " <>
          "remove it from the disk."
      )
    ]
  end

  defp their_own(facts) do
    %{
      id: :their_own,
      title: "The person makes these for themselves",
      parts:
        cloud(facts) ++
          [
            say("Do not share your own access to the cloud account."),
            say("A GitHub token that reads the releases of EHOS, as GITHUB_TOKEN."),
            say(
              "A classic GitHub token with read:packages only, as GHCR_TOKEN. " <>
                Secret.weight(:pull_credential)
            )
          ]
    }
  end

  defp cloud(%{provider: :gcp} = facts) do
    project = facts.place["project"] || "PROJECT"

    [
      run(
        "A sign-in to Google Cloud with the role roles/compute.admin on the project " <>
          "#{project}. Do not give Owner or Editor. To give the role, run:",
        [
          "gcloud projects add-iam-policy-binding #{word(project)} " <>
            "--member=#{word("user:" <> (facts.email || "EMAIL"))} --role=roles/compute.admin"
        ]
      ),
      run("Then the person signs in on their machine:", [
        "gcloud auth application-default login"
      ])
    ]
  end

  defp cloud(%{provider: :aws} = facts),
    do: [
      say(
        "An AWS profile of their own in the account #{facts.place["aws_account_id"] || "of the server"}, " <>
          "with access to EC2 in #{facts.place["region"] || "its region"}. Do not give them " <>
          "your profile or the administrator of the account."
      )
    ]

  # ehos-tools#1111: `up` reads the profile `installation.json` recorded, which the copy carries.
  defp cloud(%{provider: :oci} = facts),
    do: [
      say(
        "An Oracle user of their own in the tenancy, with an API key. Put the user in a group " <>
          "whose policy lets it manage the networks, the reserved public addresses and the " <>
          "instances."
      ),
      say(
        "In ~/.oci/config, the profile #{facts.oci_profile} with their user, their API key, " <>
          "and the tenancy and the region of the server. ehosctl server up reads this profile."
      )
    ]

  defp cloud(%{provider: :ovh} = facts),
    do: [
      say(
        "An OpenStack user of their own in the project #{facts.place["project_id"] || "of the server"}, " <>
          "with the roles Compute Operator, Network Operator and Network Security Operator."
      )
    ]

  defp in_ehos(facts) do
    n = word(facts.name)

    %{
      id: :in_ehos,
      title: "Let the person into EHOS",
      parts: [
        run(
          "Invite the person, and give them the role ehos.administrator on the whole platform:",
          [
            "ehosctl server tunnel --installation #{n}",
            "ehosctl server invite #{who(facts)} --installation #{n}",
            "ehosctl role-bindings bind ehos.administrator --to #{who(facts)} --installation #{n}"
          ]
        ),
        say(
          "The link that ehosctl server invite prints is a password. Give it only to that person."
        )
      ]
    }
  end

  defp certificates_section(facts) do
    %{id: :certificates, title: "Certificates", parts: certificate_parts(facts)}
  end

  defp certificate_parts(%{certificates: :public} = facts),
    do: [
      run(
        "The installation has certificates from Let's Encrypt. The person signs in with no CA " <>
          "file:",
        ["ehosctl login --installation #{word(facts.name)} #{url(facts)}"]
      )
      | host_said(facts)
    ]

  defp certificate_parts(%{certificates: {:own, path, fingerprint}} = facts),
    do: [
      say(
        "The installation has its own CA, in #{path}. #{Secret.weight(:ca_certificate)} Give " <>
          "the person the file."
      ),
      say(
        "Send its SHA-256 fingerprint over another channel, so that the person can check the " <>
          "file: #{fingerprint || Output.none()}"
      ),
      run("The person signs in with it:", [
        "EHOSCTL_CA_FILE=ca.crt ehosctl login --installation #{word(facts.name)} #{url(facts)}"
      ])
      | host_said(facts)
    ]

  defp certificate_parts(%{certificates: :none}),
    do: [
      say(
        "EHOS is not installed yet, so the installation has no certificate to give. Run this " <>
          "command again after ehosctl install."
      )
    ]

  defp url(%{host: nil}), do: "https://HOST"
  defp url(%{host: host}), do: word("https://" <> host)

  defp host_said(%{host: nil}), do: [say("HOST is the host of the console.")]
  defp host_said(_facts), do: []

  defp state(facts) do
    %{
      id: :state,
      title: "Decide who owns the state",
      parts: [
        say(
          "OpenTofu keeps the state of the server in a file on the workstation that ran " <>
            "ehosctl server up. Two copies of the state diverge."
        ),
        say(
          "An up or a down from an old copy can make a second server, or remove resources. " <>
            "Until the state is shared and locked, only its owner runs ehosctl server up and down."
        ),
        ssh_from(facts)
      ]
    }
  end

  defp ssh_from(facts) do
    admitted =
      case facts.ssh_from do
        [] -> "ehosctl has no record of them."
        blocks -> Enum.join(blocks, ", ") <> "."
      end

    run(
      "SSH admits only the addresses that the last up was given: #{admitted} The owner gives " <>
        "the address of each administrator to each up. ADDRESS is the public IPv4 address of " <>
        "the person:",
      ["ehosctl server up --installation #{word(facts.name)}#{kept(facts)} --ssh-from ADDRESS"]
    )
  end

  defp receiver(facts) do
    n = word(facts.name)
    key = own_key(facts)

    %{
      id: :receiver,
      title: "What the person runs on their machine",
      parts:
        [
          run(
            "Restore the copy of the installation. After this, the person owns the state:",
            restore(facts)
          )
          | restore_without_op(facts)
        ] ++
          [
            run(
              "Take the state passphrase from the password manager, and give it to this shell. " <>
                "Paste it after the command, then press Return. The terminal does not show it:",
              [
                "stty -echo; IFS= read -r EHOS_STATE_PASSPHRASE; stty echo; export EHOS_STATE_PASSPHRASE"
              ]
            ),
            say(
              "Each up replaces the addresses that SSH admits. Run ehosctl server handover again " <>
                "before you use this up later, so that it gives the addresses that SSH admits then."
            ),
            run(
              "Admit their address on SSH, and write a kubeconfig with a certificate of their " <>
                "own. ADDRESS is their public IPv4 address. NAME is the name that you gave " <>
                "them.#{account_said(facts)}",
              [
                "ehosctl server up --installation #{n}#{account(facts)} --ssh-key #{key}" <>
                  "#{kept(facts)} --ssh-from ADDRESS",
                "ehosctl server tunnel --installation #{n} --ssh-key #{key} --administrator NAME"
              ]
            ),
            run(
              "Add the installation to ehosctl, with their own GHCR_TOKEN. VERSION is the version " <>
                "of EHOS that runs: ehosctl versions --installation #{n} shows it to you.",
              [
                "ehosctl install --installation #{n} --version VERSION",
                "ehosctl login --installation #{n}"
              ]
            ),
            say(
              "On the server, ehosctl install changes only the token that the cluster pulls images with."
            )
          ]
    }
  end

  defp restore_without_op(%{op?: true}),
    do: [
      run(
        "If the person does not have the 1Password CLI, they save the document from the " <>
          "1Password app as FILE, and run:",
        restore_from_file()
      )
    ]

  defp restore_without_op(_facts), do: []

  # `up` uses the profile or the entry `installation.json` recorded, the giver's, unless given
  # another, and records it; `tunnel` reads what `up` recorded, and takes no other.
  defp account(%{provider: :aws}), do: " --aws-profile PROFILE"
  defp account(%{provider: :ovh}), do: " --os-cloud ENTRY"
  defp account(_facts), do: ""

  defp account_said(%{provider: :aws}), do: " PROFILE is their own AWS profile."
  defp account_said(%{provider: :ovh}), do: " ENTRY is their own entry in clouds.yaml."
  defp account_said(_facts), do: ""

  # Each `up` replaces the blocks SSH admits, so one that leaves them out shuts the others out.
  defp kept(facts), do: Enum.map_join(facts.ssh_from, &" --ssh-from #{word(&1)}")

  defp restore(%{op?: true} = facts),
    do: [
      "(umask 077; mkdir -p ~/.ehos && op document get #{word(copy_title(facts))} --vault " <>
        "#{word(vault(facts))} | tar xzf - -C ~/.ehos)"
    ]

  defp restore(_facts), do: restore_from_file()

  # The file a person saved is theirs to remove once its contents are in `~/.ehos`.
  defp restore_from_file,
    do: ["(umask 077; mkdir -p ~/.ehos && tar xzf FILE -C ~/.ehos) && rm FILE"]

  defp password_manager(%{op?: true} = facts) do
    vault = word(vault(facts))

    %{
      id: :password_manager,
      title: "Put the items in 1Password",
      parts: [
        run("The 1Password CLI, op, is on this machine. Make a vault for the installation:", [
          "op vault create #{vault}"
        ]),
        run(
          "Put the state passphrase in it from EHOS_STATE_PASSPHRASE. A variable of a " <>
            "subshell and a pipe carry it, so it shows on no command line. If the variable is " <>
            "not set or is empty, jq stops, op makes no item, and the command fails:",
          [
            "(item=$(op item template get Password | jq #{@passphrase_filter}) && " <>
              ~S([ -n "$item" ] && printf '%s' "$item" | op item create --vault ) <>
              "#{vault} --title #{word("ehos-#{facts.name} state passphrase")} -)"
          ]
        ),
        run(
          "Put the copy of the installation in it. tar writes it to a temporary file that only " <>
            "you can read, and op gets it only if tar succeeds. The command removes the file:",
          [
            staged(
              facts,
              "op document create #{tar_file()} --vault #{vault} --title " <>
                "#{word(copy_title(facts))}"
            )
          ]
        ),
        # A second document of the same title would make the person's `op document get` refuse,
        # or restore an old state. A failed tar leaves the last good copy as it is.
        run("After each ehosctl server up, replace the copy in the same document:", [
          staged(
            facts,
            "op document edit #{word(copy_title(facts))} #{tar_file()} --vault #{vault}"
          )
        ]),
        run("Give the person the vault:", [
          "op vault user grant --vault #{vault} --user #{who(facts)} " <>
            "--permissions allow_viewing,allow_editing"
        ])
      ]
    }
  end

  defp password_manager(facts) do
    %{
      id: :password_manager,
      title: "Put the items in the password manager",
      parts: [
        say(
          "In 1Password, make a vault for the installation and share it with the person. Add " <>
            "the state passphrase as a Password item, and the copy as a Document."
        ),
        say("If you install the 1Password CLI, op, this command prints the commands."),
        say(
          "In Apple Passwords, make a shared group with the person in it. Add the state " <>
            "passphrase to the group as a password."
        ),
        say(
          "Apple Passwords holds no files. Keep the copy of #{facts.home}/#{facts.name} in " <>
            "another place that only the installation administrators can read."
        )
      ]
    }
  end

  defp vault(facts), do: "ehos-#{facts.name}"
  defp copy_title(facts), do: "ehos-#{facts.name} copy of the installation"

  defp say(sentence), do: {sentence, []}
  defp run(sentence, commands), do: {sentence, commands}

  defp who(%{email: nil}), do: "EMAIL"
  defp who(%{email: email}), do: word(email)

  defp word(value), do: Shell.word(value)

  # A path from `~/` keeps its `~` outside quotes, so the shell expands it.
  defp shell_path("~/" <> rest), do: "~/" <> word(rest)
  defp shell_path(path), do: word(path)

  @doc """
  The words of the handover: the installation's values, then each section, its parts on lines of
  their own and each command under its sentence.
  """
  @spec text(t(), [section()]) :: Output.text()
  def text(facts, sections) do
    Output.lines(
      [
        Output.outcome(:done, "The handover of the installation #{facts.name}:"),
        Output.values(values(facts)),
        # `( … )` is a subshell in a POSIX shell and command substitution in fish.
        "The commands are for a POSIX shell, such as sh, bash or zsh.",
        if(facts.email,
          do: nil,
          else: "Give --email to put the email of the person in place of EMAIL."
        )
      ] ++ Enum.flat_map(sections, &section_text/1)
    )
  end

  defp values(facts) do
    [
      {"Provider", where(facts)},
      {"SSH key", facts.ssh_key},
      {"Certificates", certificates_value(facts.certificates)}
    ]
  end

  defp where(facts) do
    [
      Provider.title(facts.provider)
      | Enum.map(Provider.identity(facts.provider), &facts.place[&1])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp certificates_value(:public), do: "From Let's Encrypt"
  defp certificates_value({:own, path, _fingerprint}), do: "Its own CA, #{path}"
  defp certificates_value(:none), do: "None: EHOS is not installed yet"

  defp section_text(%{title: title, parts: parts}) do
    ["", Owl.Data.tag(title, :bright)] ++
      Enum.map(parts, fn
        {sentence, []} -> sentence
        {sentence, commands} -> Output.commands(sentence, commands)
      end)
  end

  @doc """
  What `--json` prints: the installation's facts and the sections, each part a sentence and its
  commands. No secret's value.
  """
  @spec json(t(), [section()]) :: map()
  def json(facts, sections) do
    %{
      "installation" => facts.name,
      "provider" => Provider.name(facts.provider),
      "place" => facts.place,
      "ssh_key" => facts.ssh_key,
      "ssh_from" => facts.ssh_from,
      "administrator" => facts.administrator,
      "certificates" => certificates_json(facts.certificates),
      "host" => facts.host,
      "email" => facts.email,
      "sections" =>
        Enum.map(sections, fn section ->
          %{
            "id" => Atom.to_string(section.id),
            "title" => section.title,
            "parts" =>
              Enum.map(section.parts, fn {sentence, commands} ->
                %{"text" => sentence, "commands" => commands}
              end)
          }
        end)
    }
  end

  defp certificates_json(:public), do: %{"kind" => "public"}
  defp certificates_json(:none), do: %{"kind" => "none"}

  defp certificates_json({:own, path, fingerprint}),
    do: %{"kind" => "own", "file" => path, "fingerprint" => fingerprint}

  defp email(nil), do: {:ok, nil}

  # EHOS takes such an address, but quoted it reads as an option, so no command could name it.
  defp email("-" <> _rest = email),
    do:
      {:error, :invalid,
       "--email: #{inspect(email)} starts with -, which a command would read as an option. " <>
         "ehosctl printed nothing."}

  defp email(email) do
    case EhosPlatform.Install.email(email) do
      {:ok, email} -> {:ok, email}
      {:error, message} -> {:error, :invalid, "--email: #{message}. ehosctl printed nothing."}
    end
  end

  # The installation's directory is the operator's own, under `~/.ehos`. A file that is not there
  # is a record not written yet: `install.json` before the first `ehosctl install`.
  # sobelow_skip ["Traversal.FileModule"]
  defp recorded(dir, file) do
    path = Path.join(dir, file)

    case File.read(path) do
      {:ok, contents} -> decoded(JSON.decode(contents), path)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> unreadable(path, :file.format_error(reason))
    end
  end

  defp decoded({:ok, %{} = map}, _path), do: {:ok, map}
  defp decoded(_other, path), do: unreadable(path, "it is not a JSON object")

  defp unreadable(path, why),
    do:
      {:error, :failed,
       "ehosctl cannot read #{path}: #{why}. Restore it from the copy of the installation in " <>
         "the password manager. ehosctl printed nothing."}

  # An installation made on Oracle before other providers has no provider recorded.
  defp provider(place, dir) do
    case Provider.parse(place["provider"] || "oci") do
      {:ok, provider} ->
        {:ok, provider}

      {:error, _unknown} ->
        unreadable(Path.join(dir, "installation.json"), "its provider is unknown")
    end
  end

  # A `ca.crt` that is not there is an installation EHOS is not installed on yet; one that cannot
  # be read is named, as a record is.
  # sobelow_skip ["Traversal.FileModule"]
  defp certificates(dir, user_home) do
    path = Path.join(dir, "ca.crt")

    case File.read(path) do
      {:ok, pem} -> certificate_kind(pem, Platform.portable_path(path, user_home))
      {:error, :enoent} -> {:ok, :none}
      {:error, reason} -> unreadable(path, :file.format_error(reason))
    end
  end

  # With public certificates, `ehosctl install` writes Let's Encrypt's roots to `ca.crt`, the ones
  # the ehosctl of that install bundled: a later one may bundle others, so the roots are told by
  # their organisation, not by the bytes of this ehosctl's bundle.
  defp certificate_kind(pem, path) do
    case certificates_in(pem) do
      :error -> unreadable(path, "it holds a certificate that ehosctl cannot read")
      [] -> {:ok, {:own, path, nil}}
      certificates -> {:ok, kind(certificates, pem, path)}
    end
  end

  defp kind(certificates, pem, path) do
    if Enum.all?(certificates, &lets_encrypt?/1),
      do: :public,
      else: {:own, path, fingerprint(pem)}
  end

  # The certificates of `pem`, decoded, or `:error` for a block that is not one: a file that was
  # cut or changed. Neither error is said, since the term holds the file's bytes.
  defp certificates_in(pem) do
    for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem),
        do: :public_key.pkix_decode_cert(der, :otp)
  rescue
    _error -> :error
  catch
    _kind, _value -> :error
  end

  @isrg ~c"Internet Security Research Group"

  defp lets_encrypt?(cert) do
    {:rdnSequence, names} = otp_tbs(otp_certificate(cert, :tbsCertificate), :subject)

    Enum.any?(List.flatten(names), fn
      {:AttributeTypeAndValue, {2, 5, 4, 10}, {_kind, @isrg}} -> true
      {:AttributeTypeAndValue, {2, 5, 4, 10}, @isrg} -> true
      _other -> false
    end)
  end

  defp openbao_warned?(name, opts) do
    env = Ehosctl.SystemEnv.current().all()
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env) end)

    case Config.read(config_dir) do
      {:ok, config} -> Config.warned?(config, name, :openbao_key)
      {:error, _kind, _message} -> false
    end
  end

  # A value of another type in a record is one ehosctl did not write: it is left out, as one not
  # recorded is, rather than put into a sentence or a command.
  defp string?({_key, value}), do: is_binary(value)

  defp string(value) when is_binary(value), do: value
  defp string(_other), do: nil

  defp printable(value) when is_binary(value),
    do: if(Output.printable?(value), do: value)

  defp printable(_other), do: nil
end
