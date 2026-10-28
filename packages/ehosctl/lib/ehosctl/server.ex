defmodule Ehosctl.Server do
  @moduledoc """
  `ehosctl server up | down | status | tunnel`: makes, reaches, reads and removes the server under
  an installation, in Oracle Cloud, AWS or GCP (eh-os D-77, D-83), with `EhosPlatform.Server`
  run through `Ehosctl.PlatformRunner` at the tool versions EHOS is tested with (T-13).

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
  line (#430); on AWS and GCP it lifts the provider's deletion protection from the server first.

  `invite <email>` runs EHOS's release command through the tunnel's kubeconfig, as the operator,
  with `EhosPlatform.Install.invite/1`: it invites the person, makes them the platform's
  administrator when nobody is, and prints the link that signs them in once, within 15 minutes.
  It needs no release, no passphrase and no sign-in, so it is how the first person of a new
  installation gets in, and how a person who forgot their password gets back in while the
  installation sends no mail (eh-os#441).
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Config
  alias Ehosctl.ServerRelease
  alias EhosPlatform.Install
  alias EhosPlatform.Server, as: Platform
  alias EhosPlatform.Server.Provider

  @impl Ehosctl.Command
  def name, do: :server

  @impl Ehosctl.Command
  def plane, do: :platform

  @where [
    installation: [
      long: "--installation",
      value_name: "NAME",
      help:
        "The installation whose server this is, instead of EHOSCTL_INSTALLATION, the current " <>
          "one, or trial."
    ],
    version: [
      long: "--version",
      value_name: "V",
      help:
        "The EHOS release whose OpenTofu modules make the server. By default the one `up` last " <>
          "used, else the newest; only `up` takes another."
    ],
    provider: [
      long: "--provider",
      value_name: "PROVIDER",
      help:
        "#{Enum.join(Provider.names(), ", ")}; `up` needs it for a server not made yet. A server " <>
          "stays where `up` made it."
    ],
    region: [
      long: "--region",
      value_name: "REGION",
      help: "On AWS, GCP and OVHcloud, the region; on Oracle, the profile's."
    ],
    aws_profile: [long: "--aws-profile", value_name: "PROFILE", help: "The AWS profile."],
    gcp_project: [long: "--gcp-project", value_name: "PROJECT", help: "The GCP project."],
    os_cloud: [
      long: "--os-cloud",
      value_name: "ENTRY",
      help: "On OVHcloud, the entry of OpenStack's clouds.yaml; OS_CLOUD's, else ovh, by default."
    ],
    ssh_key: [
      long: "--ssh-key",
      value_name: "PATH",
      help:
        "The private key to log in with; its .pub is put on the server. ~/.ssh/ehos_oci by default."
    ]
  ]

  @up [
    ssh_from: [
      long: "--ssh-from",
      value_name: "CIDR",
      multiple: true,
      help:
        "An IPv4 block SSH is admitted from, or an address alone; repeat for several. This " <>
          "machine's public addresses by default, each one several services see. Each `up` " <>
          "replaces those admitted before."
    ],
    availability_domain: [
      long: "--availability-domain",
      value_name: "N",
      parser: :integer,
      help: "Which of the region's availability domains, or zones, from 0."
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
      help: "On AWS, the EC2 instance type; on GCP, the machine type; on OVHcloud, the flavor."
    ]
  ]

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Make, reach, read and remove the server under an installation, in Oracle Cloud, AWS " <>
          "or GCP, with your cloud account and SSH key, and invite a person through it.",
      subcommands: [
        up: [
          name: "up",
          about:
            "Make the server, or bring it in line with the modules, and wait until k3s runs.",
          options: @where ++ @up,
          flags: [
            replace: [
              long: "--replace",
              help: "Let the plan remove or replace the server; refused without it."
            ]
          ]
        ],
        tunnel: [
          name: "tunnel",
          about: "Open an SSH tunnel to the server's Kubernetes API, and write its kubeconfig.",
          options:
            @where ++
              [
                port: [
                  long: "--port",
                  value_name: "PORT",
                  parser: :integer,
                  help: "The tunnel's local port; the first free one from 16443 by default."
                ]
              ],
          flags: [close: [long: "--close", help: "Close the tunnel instead."]]
        ],
        status: [
          name: "status",
          about:
            "The server's address, CPUs, memory and load, its first boot and its node; works " <>
              "with EHOS stopped.",
          options: @where
        ],
        down: [
          name: "down",
          about:
            "Remove the server and everything made with it, once the installation's name is " <>
              "typed. Nothing removed can be brought back.",
          options: @where,
          flags: [
            yes: [
              long: "--yes",
              help: "Do not ask; taken only with --installation naming the installation."
            ]
          ]
        ],
        invite: [
          name: "invite",
          about:
            "Print a link that signs a person in once, within 15 minutes, inviting them if they " <>
              "are new; the first invited while nobody is the platform's administrator becomes " <>
              "it. Through the tunnel, as the operator. The link is a password.",
          args: [
            email: [
              value_name: "EMAIL",
              required: true,
              help: "Their email: a new person's, or that of one who forgot their password."
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
  `EhosPlatform.Install`), `:home` (where installations are kept, `~/.ehos`),
  `:config_dir`, `:ask` (asks a question, returns the answer, or nil when there is none),
  `:progress`, `:runner`, and `Ehosctl.GitHub`'s options.
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
               home: Keyword.get(opts, :home, "~/.ehos"),
               runner: Keyword.get(opts, :runner, Ehosctl.PlatformRunner),
               server_command: "ehosctl server",
               # The tunnel it says to open names this installation, as every command ehosctl
               # suggests does (#194).
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
         {:ok, platform_opts, pending?} <- with_source(subcommand, parsed, base, opts),
         {:ok, message} <- run(subcommand, server, parsed, platform_opts, pending?) do
      {:ok, %{text: message, json: nil}}
    end
  end

  @doc """
  The installation's name: `flag`, else `EHOSCTL_INSTALLATION`, else the current installation,
  else `trial` (T-13), for a command that needs, by `need`:

    * `:server` (the default), a server already made: its state kept under `~/.ehos/<name>/`, as
      `EhosPlatform.Server.made?/1` reads it. A name with none is refused, naming the
      installations that have one, since the server may well be under another name than the
      current installation's (#194): one made before `ehosctl login` named installations after
      their host is under `trial`;
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
          {:ok, String.t()} | {:error, Ehosctl.Output.kind(), String.t()}
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
             message <> "; or name the installation with --installation or EHOSCTL_INSTALLATION"}
        end
    end
  end

  defp known(:up, name, from, [_ | _] = servers, _opts) when from in [:current, :default] do
    if name in servers do
      {:ok, name}
    else
      new_one =
        if Platform.valid_name?(name),
          do: "--installation #{name} --provider PROVIDER (#{providers()}) to make a new one",
          else: "a name of its own to make a new one (#{Platform.name_rule()})"

      {:error, :invalid,
       "No server is known under #{shown(name, from)}; #{servers_said(servers)}. `up` " <>
         "makes a new server only under a name it is given: run it again with " <>
         "#{which(servers)} to bring that server in line, or with #{new_one}."}
    end
  end

  defp known(:up, name, from, _servers, _opts) do
    if Platform.valid_name?(name),
      do: {:ok, name},
      else:
        {:error, :invalid, "#{shown(name, from)} cannot name a server: #{Platform.name_rule()}"}
  end

  defp known(:server, name, from, servers, opts) do
    cond do
      name in servers ->
        {:ok, name}

      servers == [] ->
        up = if Platform.valid_name?(name), do: name, else: "<name>"

        {:error, :failed,
         "No server is known under #{shown(name, from)}, nor under any other installation in " <>
           "#{home(opts)}. Make one with `ehosctl server up --provider PROVIDER --installation " <>
           "#{up}`, PROVIDER one of #{providers()}."}

      true ->
        {:error, :invalid,
         "No server is known under #{shown(name, from)}; #{servers_said(servers)}. Run the " <>
           "command again with #{which(servers)}."}
    end
  end

  defp servers_said([one]), do: "the one on this machine is #{one}'s"
  defp servers_said(servers), do: "servers on this machine: #{Enum.join(servers, ", ")}"

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
  # listed (#345).
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

  defp home(opts), do: opts |> Keyword.get(:home, "~/.ehos") |> Path.expand()

  defp base_opts(name, parsed, opts) do
    options = parsed.options
    home = Keyword.get(opts, :home, "~/.ehos")

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
      runner: Keyword.get(opts, :runner, Ehosctl.PlatformRunner),
      progress: Keyword.get(opts, :progress, &progress/1),
      command: "ehosctl server",
      name_option: "--installation",
      # A command suggested by name reaches this server whichever installation is current when
      # it runs, as one suggested after `--installation` would not otherwise (#194).
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
  # installation (#430).
  defp confirmed(:down, name, parsed, opts) do
    ask = Keyword.get(opts, :ask, &ask/1)

    cond do
      parsed.flags[:yes] and parsed.options[:installation] == nil ->
        # The name it came to is not put into a command to copy: it is the one --yes refuses.
        {:error, :invalid,
         "Nothing removed: --yes is taken only with --installation naming, on the command " <>
           "line, the installation whose server it removes, not one from " <>
           "EHOSCTL_INSTALLATION or the current installation (#{name} here)."}

      parsed.flags[:yes] ->
        :ok

      typed?(ask.(lost(name, opts)), name) ->
        :ok

      true ->
        {:error, :failed,
         "Nothing removed: the installation's name, #{name}, was not typed. Run " <>
           "`ehosctl server down --installation #{name}` again to remove its server."}
    end
  end

  defp confirmed(_subcommand, _name, _parsed, _opts), do: :ok

  # The modules from the release (`Ehosctl.ServerRelease`), and whether `up` downloaded one it
  # keeps only once it has succeeded.
  defp with_source(subcommand, parsed, base, opts) do
    dir = Platform.dir(base)

    cond do
      # Closing a tunnel needs no modules.
      subcommand == :tunnel and parsed.flags[:close] ->
        {:ok, base, false}

      # Nor does one without the state's passphrase, which `EhosPlatform.Server` refuses first,
      # saying so: nothing is downloaded or kept for a command that cannot run.
      not Platform.valid_passphrase?(base[:passphrase]) ->
        {:ok, base, false}

      true ->
        command = if subcommand == :up, do: :up, else: :other

        with {:ok, source, _version, pending?} <-
               ServerRelease.source(dir, parsed.options[:version], command, opts),
             do: {:ok, Keyword.put(base, :source, source), pending?}
    end
  end

  defp passphrase(opts) do
    env = Ehosctl.SystemEnv.current().all()
    Keyword.get(opts, :passphrase, env["EHOS_STATE_PASSPHRASE"])
  end

  # A release `up` downloaded is kept once `up` has applied it, which the state changing shows,
  # whether or not what came after the apply succeeded; a plan refused or failed before the apply
  # leaves the release kept before.
  defp run(:up, server, _parsed, platform_opts, pending?) do
    dir = Platform.dir(platform_opts)
    state = state(dir)
    result = platform(server.up(platform_opts))

    cond do
      not pending? -> result
      match?({:ok, _}, result) or state(dir) != state -> keep_applied(result, dir, platform_opts)
      true -> tap(result, fn _ -> ServerRelease.discard(dir) end)
    end
  end

  defp run(:tunnel, server, parsed, platform_opts, _pending?) do
    if parsed.flags[:close],
      do: platform(server.close_tunnel(platform_opts)),
      else: platform(server.tunnel(platform_opts))
  end

  defp run(:status, server, _parsed, platform_opts, _pending?),
    do: platform(server.status(platform_opts))

  defp run(:down, server, _parsed, platform_opts, _pending?),
    do: platform(server.down(platform_opts))

  defp keep_applied(result, dir, platform_opts) do
    case ServerRelease.keep(dir) do
      :ok ->
        result

      {:error, kind, why} ->
        said = with({_ok_or_error, message} <- result, do: message)

        {:error, kind,
         "#{said}\nThe server was made from the modules of #{Path.join(dir, "release.next")}, " <>
           "but they could not be kept: #{why}. Run `ehosctl server up --installation " <>
           "#{platform_opts[:name]} --version <that release>` to keep them."}
    end
  end

  # What OpenTofu's state is: it changes when an apply writes it.
  defp state(dir) do
    case File.read(Path.join(dir, "terraform.tfstate")) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, _} -> nil
    end
  end

  # eh-os D-126: an `up` for a server not made yet names its cloud, before a release is looked for
  # or downloaded: the command line's error, or a failure when the installation's record cannot be
  # read (#345).
  defp provider_named(:up, base), do: Platform.provider_named(base)

  defp provider_named(_subcommand, _base), do: :ok

  # The providers a command to copy may name, one of which replaces PROVIDER: `aws|gcp` would be a
  # pipeline in a shell.
  defp providers, do: Enum.join(Provider.names(), ", ")

  defp platform({:ok, message}), do: {:ok, message}
  defp platform({:error, message}), do: {:error, :failed, message}

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
          "The link is a password: whoever opens it is signed in as that person. Give it to " <>
          "them alone, in a direct message to an account you know is theirs, never in a " <>
          "channel, a ticket or a thread others read. It works once, until it is used or its " <>
          "15 minutes pass, and a new one does not end it. If anyone else may have seen it, " <>
          "disable the person (`ehosctl people disable #{email} --installation #{name}`), " <>
          "which ends every link they hold, " <>
          "then enable them and run this command again; the platform's only administrator " <>
          "cannot be disabled, so they open it at once, which uses it up."
      ],
      "\n"
    )
  end

  # A line may hold what the server printed, as cloud-init's errors (#165).
  defp progress(line), do: IO.puts(:stderr, "==> " <> Ehosctl.Output.shown_lines(line))

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
    This removes the server of the installation #{name}#{where}, for good:
      - the server ehos-#{name} and its disk, with EHOS's database and every application's
        database on it;
      - its network;
      - its public address, which goes back to #{provider} and may be given to anyone: take it
        out of whatever admits it, such as a mail relay's rule.
    EHOS makes no backups yet, so nothing removed can be brought back.
    #{serves}
    Type the installation's name, #{name}, to remove its server:\
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

  # A question with no answer, as a script's stdin gives, is nil.
  defp ask(question) do
    case IO.gets(:stdio, question <> " ") do
      answer when is_binary(answer) -> answer
      _eof -> nil
    end
  end
end
