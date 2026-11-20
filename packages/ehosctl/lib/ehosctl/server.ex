defmodule Ehosctl.Server do
  @moduledoc """
  `ehosctl server up | down | status | tunnel`: makes, reaches, reads and removes the server under
  an installation, in Oracle Cloud, AWS, GCP or OVHcloud (eh-os D-77, D-83), with
  `EhosPlatform.Server` run through `Ehosctl.PlatformRunner` at the tool versions EHOS is tested
  with (T-13).

  The installation is the one `--installation` names, else `EHOSCTL_INSTALLATION`, else the
  current one, else `trial` (T-13), and its server's files are in `~/.ehos/<name>/`, as
  `mix ehos.server` keeps them, so a server made with Mix is read as it is. Every command but
  `up` refuses a name no server's state is kept under, naming those that have one, and `up`
  makes no new server under a name it was not given while another installation has one
  (`installation/3`); every command it suggests names the installation. The OpenTofu modules
  come from an EHOS release (`Ehosctl.ServerRelease`), never a checkout.

  `EHOS_STATE_PASSPHRASE` encrypts OpenTofu's state; the provider's credentials are where its
  own tools keep them, as `ehosctl doctor` reports. `down` says what is lost and removes nothing
  until the installation's name is typed, or `--yes` is given with `--installation` on the command
  line (ehos-tools#430); on AWS and GCP it lifts the provider's deletion protection from the
  server first.

  `invite <email>` runs EHOS's release command through the tunnel's kubeconfig, as the operator,
  with `EhosPlatform.Install.invite/1`: it invites the person, makes them the platform's
  administrator when nobody is, and prints the link that signs them in once, within 15 minutes.
  It needs no release, no passphrase and no sign-in, so it is how the first person of a new
  installation gets in, and how a person who forgot their password gets back in while the
  installation sends no mail (eh-os#441).
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Config
  alias Ehosctl.Failure
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.ServerRelease
  alias EhosPlatform.Install
  alias EhosPlatform.Report
  alias EhosPlatform.Server, as: Platform
  alias EhosPlatform.Server.Provider

  @impl Ehosctl.Command
  def name, do: :server

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def group, do: :installation

  @impl Ehosctl.Command
  def summary, do: "Make, reach, read and remove the server of an installation."

  @where [
    installation: [
      long: "--installation",
      value_name: "NAME",
      help:
        "The installation of the server. By default EHOSCTL_INSTALLATION, else the current " <>
          "installation, else trial."
    ],
    version: [
      long: "--version",
      value_name: "V",
      help:
        "The release of EHOS whose OpenTofu modules make the server. By default the release " <>
          "that `up` used last, else the newest. Only `up` takes another release."
    ],
    provider: [
      long: "--provider",
      value_name: "PROVIDER",
      help:
        "The cloud of the server: #{Enum.join(Provider.names(), ", ")}. `up` needs it for a new " <>
          "server. A server stays in the cloud where `up` made it."
    ],
    region: [
      long: "--region",
      value_name: "REGION",
      help: "The region on AWS, GCP and OVHcloud. On Oracle, the region of the profile."
    ],
    aws_profile: [long: "--aws-profile", value_name: "PROFILE", help: "The AWS profile."],
    gcp_project: [long: "--gcp-project", value_name: "PROJECT", help: "The GCP project."],
    os_cloud: [
      long: "--os-cloud",
      value_name: "ENTRY",
      help: "On OVHcloud, the entry in clouds.yaml of OpenStack. By default OS_CLOUD, else ovh."
    ],
    ssh_key: [
      long: "--ssh-key",
      value_name: "PATH",
      help:
        "The private key to log in with. `up` puts its .pub on the server and records the key. " <>
          "By default the key that `up` recorded, else ~/.ssh/ehos_oci."
    ]
  ]

  @up [
    ssh_from: [
      long: "--ssh-from",
      value_name: "CIDR",
      multiple: true,
      help:
        "An IPv4 block or address that the server admits SSH from, /16 or narrower. Repeat it " <>
          "for several. By default the public addresses of this machine. Each `up` replaces " <>
          "the blocks before."
    ],
    availability_domain: [
      long: "--availability-domain",
      value_name: "N",
      parser: :integer,
      help: "The number of the availability domain, or zone, in the region, from 0."
    ],
    ocpus: [long: "--ocpus", value_name: "N", parser: :integer, help: "On Oracle, the OCPUs."],
    memory_gb: [
      long: "--memory-gb",
      value_name: "N",
      parser: :integer,
      help: "On Oracle, the memory in GB."
    ],
    instance_type: [
      long: "--instance-type",
      value_name: "TYPE",
      help: "The EC2 instance type on AWS, the machine type on GCP, or the flavor on OVHcloud."
    ]
  ]

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Make, reach, read and remove the server of an installation in Oracle Cloud, AWS, GCP " <>
          "or OVHcloud. Invite a person through the server.",
      subcommands: [
        up: [
          name: "up",
          about: "Make the server, or change it to match the modules, and wait until k3s runs.",
          options: @where ++ @up,
          flags: [
            replace: [
              long: "--replace",
              help:
                "Let the plan remove or replace the server. Without this flag, ehosctl refuses " <>
                  "such a plan."
            ],
            public_certificates: [
              long: "--public-certificates",
              help:
                "Open port 53 over UDP and TCP, for an installation with certificates from " <>
                  "Let's Encrypt (`ehosctl install --public-certificates`). A later up keeps it."
            ]
          ]
        ],
        tunnel: [
          name: "tunnel",
          about:
            "Open an SSH tunnel to the Kubernetes API of the server, and write its kubeconfig.",
          options:
            @where ++
              [
                port: [
                  long: "--port",
                  value_name: "PORT",
                  parser: :integer,
                  help: "The local port of the tunnel. By default the first free port from 16443."
                ]
              ],
          flags: [close: [long: "--close", help: "Close the tunnel instead."]]
        ],
        status: [
          name: "status",
          about:
            "Show the address, CPUs, memory and load of the server, its first boot and its " <>
              "node. It works when EHOS is stopped.",
          options: @where
        ],
        down: [
          name: "down",
          about:
            "Remove the server and all that was made with it, after you type the name of the " <>
              "installation. You cannot get back what it removes.",
          options: @where,
          flags: [
            yes: [
              long: "--yes",
              help:
                "Do not ask for the name. ehosctl accepts it only with --installation on the " <>
                  "command line."
            ]
          ]
        ],
        invite: [
          name: "invite",
          about:
            "Print a link that signs a person in one time, within 15 minutes. It invites a new " <>
              "person. If the platform has no administrator, the person becomes it. The link is " <>
              "a password. The command goes through the tunnel that `ehosctl server tunnel` " <>
              "opens.",
          args: [
            email: [
              value_name: "EMAIL",
              required: true,
              help: "The email of a new person, or of a person who forgot their password."
            ]
          ],
          options: Keyword.take(@where, [:installation])
        ]
      ]
    ]
  end

  @doc """
  Runs the subcommand in `path`. `opts` may name, for tests, `:server` (the module that does the
  work, `EhosPlatform.Server` by default), `:install` (the one that invites,
  `EhosPlatform.Install`), `:home` (where installations are kept, `~/.ehos`), `:config_dir`,
  `:runner`, and `Ehosctl.GitHub`'s options.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:invite], parsed, opts) do
    install = Keyword.get(opts, :install, Install)

    # The address is checked before anything runs, so one EHOS would refuse is the command line's
    # error; the platform checks it again before it writes it into what EHOS evaluates.
    with {:ok, email} <- invalid(Install.email(parsed.args.email)),
         {:ok, name} <- installation(parsed.options[:installation], opts),
         {:ok, invited} <-
           platform(
             install.invite(
               email: email,
               name: name,
               home: home(opts),
               runner: Keyword.get(opts, :runner, Ehosctl.PlatformRunner),
               server_command: "ehosctl server",
               # The tunnel it says to open names this installation, as every command ehosctl
               # suggests does (ehos-tools#194).
               name_option: "--installation",
               name_in_commands: true
             )
           ) do
      {:ok, %{text: invited(invited, email, name), json: nil}}
    end
  end

  def call([subcommand], parsed, opts) do
    server = Keyword.get(opts, :server, Platform)
    options = parsed.options

    need = if subcommand == :up, do: :up, else: :server

    with {:ok, name} <- installation(options[:installation], opts, need),
         base = base_opts(name, parsed, opts),
         :ok <- provider_named(subcommand, base),
         :ok <- confirmed(subcommand, name, parsed, opts),
         {:ok, platform_opts, pending} <- with_source(subcommand, parsed, base, opts),
         {:ok, message} <- run(subcommand, server, parsed, platform_opts, pending, opts) do
      {:ok, %{text: message, json: nil}}
    end
  end

  @doc """
  Where the servers' files are kept: `opts[:home]`, else `~/.ehos` in the home directory
  `Ehosctl.OS` gives.
  """
  @spec home(keyword()) :: Path.t()
  def home(opts),
    do:
      opts
      |> Keyword.get_lazy(:home, fn -> Path.join(Ehosctl.OS.current().home(), ".ehos") end)
      |> Path.expand()

  @doc """
  The installation's name: `flag`, else `EHOSCTL_INSTALLATION`, else the current installation,
  else `trial` (T-13), for a command that needs, by `need`:

    * `:server` (the default), a server already made: its state kept under `~/.ehos/<name>/`, as
      `EhosPlatform.Server.made?/1` reads it. A name with none is refused, naming the
      installations that have one, since the server may well be under another name than the
      current installation's (ehos-tools#194): one made before `ehosctl login` named
      installations after their host is under `trial`;
    * `:up`, a name the OpenTofu module takes as well as T-07's. When the name was not given,
      but is the current installation's or the fallback `trial`, and no server is under it while
      another installation has one, it is refused too, rather than a second server made:
      `--installation` says which is meant.

  A refusal for want of a server exits as `:invalid` when another installation has one, since
  naming it is the fix, and as `:failed` when this machine has none.

  `opts` may name `:home` (`~/.ehos`), `:server` (the module whose `made?/1` is asked) and
  `:config_dir`.
  """
  @spec installation(String.t() | nil, keyword(), :server | :up) ::
          {:ok, String.t()} | {:error, Ehosctl.Output.kind(), Ehosctl.Failure.message()}
  def installation(flag, opts, need \\ :server) do
    with {:ok, name, from} <- named(flag, opts),
         do: known(need, name, from, servers(opts), opts)
  end

  # The name, and where it came from.
  defp named(flag, opts) do
    env = Ehosctl.SystemEnv.current().all()
    from_env = env["EHOSCTL_INSTALLATION"]

    cond do
      flag != nil ->
        {:ok, flag, :flag}

      from_env not in [nil, ""] ->
        {:ok, from_env, :env}

      true ->
        config_dir = Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env) end)

        case Config.read(config_dir) do
          {:ok, %Config{current: nil}} ->
            {:ok, "trial", :default}

          {:ok, %Config{current: current}} ->
            {:ok, current, :current}

          {:error, kind, message} ->
            {:error, kind,
             Failure.added(
               message,
               " You can also name the installation with --installation or EHOSCTL_INSTALLATION."
             )}
        end
    end
  end

  defp known(:up, name, from, [_ | _] = servers, _opts) when from in [:current, :default] do
    if name in servers do
      {:ok, name}
    else
      new_one =
        if Platform.valid_name?(name),
          do: "--installation #{name} --provider PROVIDER (#{providers()}) to make a new server",
          else: "a new name to make a new server (#{Platform.name_rule()})"

      {:error, :invalid,
       "This computer has no server for the installation #{shown(name, from)}. " <>
         "#{servers_said(servers)}. `up` makes a new server only for a name that you give. Run it again with " <>
         "#{which(servers)} to change that server, or with #{new_one}."}
    end
  end

  defp known(:up, name, from, _servers, _opts) do
    if Platform.valid_name?(name),
      do: {:ok, name},
      else:
        {:error, :invalid,
         "#{shown(name, from)} cannot be the name of a server: #{Platform.name_rule()}"}
  end

  defp known(:server, name, from, servers, opts) do
    cond do
      name in servers ->
        {:ok, name}

      servers == [] ->
        up = if Platform.valid_name?(name), do: name, else: "<name>"

        {:error, :failed,
         "This computer has no server for the installation #{shown(name, from)}, or for another " <>
           "installation in #{home(opts)}. Make one with `ehosctl server up --provider PROVIDER " <>
           "--installation #{up}`, where PROVIDER is one of #{providers()}."}

      true ->
        {:error, :invalid,
         "This computer has no server for the installation #{shown(name, from)}. " <>
           "#{servers_said(servers)}. Run the command again with #{which(servers)}."}
    end
  end

  defp servers_said([one]), do: "It has a server for the installation #{one}"

  defp servers_said(servers),
    do: "It has servers for the installations #{Enum.join(servers, ", ")}"

  defp which([one]), do: "--installation #{one}"
  defp which(_servers), do: "--installation and one of them"

  # The name as the operator should read it, with where it came from when they did not type it.
  defp shown(name, from) do
    said = Ehosctl.Refusal.shown(name)

    case from do
      :flag -> said
      :env -> "#{said} (EHOSCTL_INSTALLATION)"
      :current -> "#{said} (the current installation)"
      :default -> "#{said} (no installation is named or current)"
    end
  end

  # The installations whose server's state is kept under `home`, as `EhosPlatform.Server.made?/1`
  # says: variables kept after `up` recorded where the server is, or Oracle's from before D-83. A
  # directory of the operator's own files, or one an `up` left before it made anything, is not
  # listed (ehos-tools#345).
  defp servers(opts) do
    server = Keyword.get(opts, :server, Platform)
    home = home(opts)

    case File.ls(home) do
      {:ok, names} ->
        names
        |> Enum.filter(&(Platform.valid_name?(&1) and server.made?(home: home, name: &1)))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp base_opts(name, parsed, opts) do
    options = parsed.options
    home = home(opts)

    options
    |> Map.take([
      :provider,
      :region,
      :aws_profile,
      :gcp_project,
      :os_cloud,
      :ssh_key,
      :availability_domain,
      :ocpus,
      :memory_gb,
      :instance_type,
      :port
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Keyword.new()
    |> Keyword.merge(
      name: name,
      home: home,
      ssh_from: options[:ssh_from] || [],
      replace: parsed.flags[:replace] == true,
      public_certificates: parsed.flags[:public_certificates] == true,
      runner: Keyword.get(opts, :runner, Ehosctl.PlatformRunner),
      progress: &Ehosctl.PlatformReport.progress/1,
      command: "ehosctl server",
      release_option: "--version",
      name_option: "--installation",
      # A command suggested by name reaches this server whichever installation is current when
      # it runs, as one suggested after `--installation` would not otherwise (ehos-tools#194).
      name_in_commands: true
    )
    |> Keyword.put(:passphrase, passphrase(opts))
  end

  # `down` says what is lost and asks for the installation's name before anything else, a download
  # included; one never made was refused before (`installation/3`). Only the exact name goes on, as
  # when GitHub deletes a repository: a `y` typed out of habit, or an installation mistaken for
  # the current one, removes nothing, and the command fails so a script sees it. `--yes` asks
  # nothing, and is taken only with `--installation` on the command line itself, so a script says
  # in its own words which server it removes, never through EHOSCTL_INSTALLATION or the current
  # installation (ehos-tools#430).
  defp confirmed(:down, name, parsed, opts) do
    cond do
      parsed.flags[:yes] and parsed.options[:installation] == nil ->
        # The name it came to is not put into a command to copy: it is the one --yes refuses.
        {:error, :invalid,
         "ehosctl removed nothing. --yes needs --installation on the command line, with the " <>
           "installation whose server it removes. EHOSCTL_INSTALLATION and the current " <>
           "installation (#{name} here) do not count."}

      parsed.flags[:yes] ->
        :ok

      typed?(Ehosctl.Terminal.current().gets(lost(name, opts) <> " "), name) ->
        :ok

      true ->
        {:error, :failed,
         "ehosctl removed nothing, because you did not type the name of the installation, " <>
           "#{name}. To remove its server, run `ehosctl server down --installation #{name}` again."}
    end
  end

  defp confirmed(_subcommand, _name, _parsed, _opts), do: :ok

  # The modules from the release (`Ehosctl.ServerRelease`), and the version of one `up` downloaded
  # and keeps only once it has succeeded, or nil.
  defp with_source(subcommand, parsed, base, opts) do
    dir = Platform.dir(base)

    cond do
      # Closing a tunnel needs no modules.
      subcommand == :tunnel and parsed.flags[:close] ->
        {:ok, base, nil}

      # Nor does one without the state's passphrase, which `EhosPlatform.Server` refuses first,
      # saying so: nothing is downloaded or kept for a command that cannot run.
      not Platform.valid_passphrase?(base[:passphrase]) ->
        {:ok, base, nil}

      true ->
        command = if subcommand == :up, do: :up, else: :other

        with {:ok, source, version, pending?} <-
               ServerRelease.source(dir, parsed.options[:version], command, opts),
             do: {:ok, Keyword.put(base, :source, source), pending(version, pending?)}
    end
  end

  defp pending(version, true), do: version
  defp pending(_version, false), do: nil

  defp passphrase(opts) do
    env = Ehosctl.SystemEnv.current().all()
    Keyword.get(opts, :passphrase, env["EHOS_STATE_PASSPHRASE"])
  end

  # A release `up` downloaded is kept once `up` has applied it, which the state changing shows,
  # whether or not what came after the apply succeeded; a plan refused or failed before the apply
  # leaves the release kept before.
  defp run(:up, server, _parsed, platform_opts, pending, _opts) do
    dir = Platform.dir(platform_opts)
    state = state(dir)
    result = platform(server.up(platform_opts))

    cond do
      is_nil(pending) ->
        result

      match?({:ok, _}, result) or state(dir) != state ->
        keep_applied(result, dir, platform_opts, pending)

      true ->
        tap(result, fn _ -> ServerRelease.discard(dir) end)
    end
  end

  defp run(:tunnel, server, parsed, platform_opts, _pending, _opts) do
    if parsed.flags[:close],
      do: platform(server.close_tunnel(platform_opts)),
      else: platform(server.tunnel(platform_opts))
  end

  defp run(:status, server, _parsed, platform_opts, _pending, _opts),
    do: platform(server.status(platform_opts))

  defp run(:down, server, _parsed, platform_opts, _pending, opts),
    do: platform_opts |> server.down() |> forget_warning(platform_opts[:name], opts) |> platform()

  # After `down`, ehosctl still knows the installation, and may keep a sign-in to it, which the
  # removal of the server's folder does not end: a warning says how to forget both, for a server
  # that is not made again (ehos-tools#1016). A later `login` adds it again for one that is.
  # `console/2` answers for an installation that `config.json` holds, and only for one.
  defp forget_warning({:ok, %Report{} = report}, name, opts) do
    if console(name, opts) do
      word = EhosPlatform.Shell.word(name)

      warning =
        {"ehosctl still knows the installation #{name}.",
         "If you do not make the server again, remove your sign-in and the installation from " <>
           "ehosctl:\n  ehosctl logout --installation #{word}\n  ehosctl installations remove #{word}"}

      {:ok, %{report | warnings: report.warnings ++ [warning]}}
    else
      {:ok, report}
    end
  end

  defp forget_warning(result, _name, _opts), do: result

  # What ehosctl could not keep comes first, with the command that keeps it, and then what `up`
  # said, whether it succeeded or failed after the apply.
  defp keep_applied(result, dir, platform_opts, version) do
    case ServerRelease.keep(dir) do
      :ok ->
        result

      {:error, kind, why} ->
        {:error, kind,
         Output.lines([
           "ehosctl could not keep the modules in #{Path.join(dir, "release.next")} that made " <>
             "the server. #{why}",
           Output.what_to_do(
             [
               "ehosctl server up --installation #{platform_opts[:name]} --version " <>
                 Refusal.shown(version)
             ],
             "To keep them, run:"
           ),
           "",
           up_said(result)
         ])}
    end
  end

  defp up_said({:ok, text}), do: ["`up` made the server:\n", text]

  defp up_said({:error, _kind, message}),
    do: ["After the apply, `up` failed: ", to_string(message)]

  # What OpenTofu's state is: it changes when an apply writes it.
  defp state(dir) do
    case File.read(Path.join(dir, "terraform.tfstate")) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, _} -> nil
    end
  end

  # eh-os D-126: an `up` for a server not made yet names its cloud, before a release is looked for
  # or downloaded: the command line's error, or a failure when the installation's record cannot be
  # read (ehos-tools#345).
  defp provider_named(:up, base), do: Platform.provider_named(base)

  defp provider_named(_subcommand, _base), do: :ok

  # The providers a command to copy may name, one of which replaces PROVIDER: `aws|gcp` would be a
  # pipeline in a shell.
  defp providers, do: Enum.join(Provider.names(), ", ")

  defp platform({:ok, %Report{} = report}), do: {:ok, Ehosctl.PlatformReport.text(report)}
  # What `EhosPlatform.Install.invite/1` gives, which `invited/3` words.
  defp platform({:ok, invited}), do: {:ok, invited}

  defp platform({:error, message}),
    do: {:error, :failed, Ehosctl.PlatformReport.failure(message)}

  defp invalid({:ok, value}), do: {:ok, value}
  defp invalid({:error, message}), do: {:error, :invalid, message}

  # What EHOS printed, as it printed it, the link on a line of its own so it can be copied alone,
  # and what to do with it: the link is a password for that person's account.
  defp invited(%{invited: invited, link: link} = said, email, name) do
    Enum.join(
      [
        invited,
        "",
        "    " <> link,
        "",
        Enum.map_join(
          [said[:administrator], said[:interrupted]],
          &if(&1, do: &1 <> "\n", else: "")
        ) <>
          "The link is a password: each person who opens it signs in as that person. Give it " <>
          "only to that person, in a direct message to an account that you know is theirs. " <>
          "Do not put it in a channel, a ticket or a thread that others read. The link works " <>
          "one time, for 15 minutes. A new link does not end it. If another person possibly " <>
          "saw it, run `ehosctl people disable #{shell_word(email)} --installation " <>
          "#{shell_word(name)}`. This ends " <>
          "each link of the person. Then enable the person and run this command again. " <>
          "Nobody can disable the only administrator of the platform: that person must open " <>
          "the link at once, which uses it."
      ],
      "\n"
    )
  end

  defp typed?(answer, name) when is_binary(answer), do: String.trim(answer) == name
  defp typed?(_no_answer, _name), do: false

  # What `down` removes, said where the decision is made, as eh-os's INSTALLING.md says it
  # ("Removing everything"), and the question. The provider and region are the ones `up`
  # recorded, and the console's address the one `ehosctl login` knows the installation at, so it
  # is plain which installation this is; either is left out when not known.
  defp lost(name, opts) do
    {where, provider} =
      case Platform.description(Platform.dir(home: home(opts), name: name), name) do
        {:ok, %{"provider" => provider} = described} ->
          title =
            case Provider.parse(provider) do
              {:ok, parsed} -> Provider.title(parsed)
              {:error, _unknown} -> provider
            end

          region = if described["region"], do: " in #{described["region"]}", else: ""
          {" on #{title}#{region}", title}

        _unknown ->
          {"", "the provider"}
      end

    serves =
      case console(name, opts) do
        nil -> ""
        url -> "The installation #{name} serves #{url}.\n"
      end

    """
    This removes the server of the installation #{name}#{where}, permanently:
      - the server ehos-#{name} and its disk, with the database of EHOS and the database of
        each application on it;
      - its network;
      - its public address, which goes back to #{provider}, who can give it to anyone:
        remove it from each rule that admits it, such as the rule of a mail relay.
    EHOS makes no backups yet, so you cannot get back what this removes.
    #{serves}
    Type the name of the installation, #{name}, to remove its server:\
    """
  end

  defp console(name, opts) do
    env = Ehosctl.SystemEnv.current().all()
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env) end)

    case Config.read(config_dir) do
      {:ok, %Config{installations: %{^name => %{"url" => url}}}} -> url
      _unknown -> nil
    end
  end

  # A word a shell passes as one argument, as the person will paste it: quoted when it holds
  # anything beyond letters, digits and `@._+-`.
  defp shell_word(word) do
    if Regex.match?(~r/\A[A-Za-z0-9@._+-]+\z/, word),
      do: word,
      else: "'" <> String.replace(word, "'", ~S('\'')) <> "'"
  end
end
