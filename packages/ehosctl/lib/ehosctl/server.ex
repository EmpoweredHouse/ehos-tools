defmodule Ehosctl.Server do
  @moduledoc """
  `ehosctl server up | down | status | tunnel`: makes, reaches, reads and removes the server under
  an installation, in Oracle Cloud, AWS or GCP (eh-os D-77, D-83), with `EhosPlatform.Server`
  run through `Ehosctl.PlatformRunner` at the tool versions EHOS is tested with (T-13).

  The installation is the one `--installation` names, else `EHOSCTL_INSTALLATION`, else the
  current one, else `trial` (T-13), and its server's files are in `~/.ehos/<name>/`, as
  `mix ehos.server` keeps them, so a server made with Mix is read as it is. Every command but
  `up` refuses a name no server's state is kept under, naming those that have one
  (`installation/3`), and every command it suggests names the installation. The OpenTofu
  modules come from an EHOS release (`Ehosctl.ServerRelease`), never a checkout.

  `EHOS_STATE_PASSPHRASE` encrypts OpenTofu's state; the provider's credentials are where its
  own tools keep them, as `ehosctl doctor` reports. `down` names the installation and asks before
  it removes anything, unless `--yes`.
  """

  @behaviour Ehosctl.Command

  alias EhosPlatform.Server, as: Platform
  alias Ehosctl.Config
  alias Ehosctl.ServerRelease

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
      help: "oci, aws or gcp; Oracle's unless given. A server stays where `up` made it."
    ],
    region: [
      long: "--region",
      value_name: "REGION",
      help: "On AWS and GCP, the region; on Oracle, the profile's."
    ],
    aws_profile: [long: "--aws-profile", value_name: "PROFILE", help: "The AWS profile."],
    gcp_project: [long: "--gcp-project", value_name: "PROJECT", help: "The GCP project."],
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
          "machine's public address by default. Each `up` replaces those admitted before."
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
      help: "On AWS, the EC2 instance type; on GCP, the machine type."
    ]
  ]

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Make, reach, read and remove the server under an installation, in Oracle Cloud, AWS " <>
          "or GCP, with your cloud account and SSH key.",
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
          about: "Remove the server and everything made with it, after asking.",
          options: @where,
          flags: [yes: [long: "--yes", help: "Do not ask."]]
        ]
      ]
    ]
  end

  @doc """
  Runs the subcommand in `path`. `opts` may name, for tests, `:server` (the module that does the
  work, `EhosPlatform.Server` by default), `:home` (where installations are kept, `~/.ehos`),
  `:env`, `:config_dir`, `:confirm` (asks a question, returns whether the answer was yes),
  `:progress`, and `Ehosctl.GitHub`'s options.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([subcommand], parsed, opts) do
    server = Keyword.get(opts, :server, Platform)
    options = parsed.options

    need = if subcommand == :up, do: :up, else: :server

    with {:ok, name} <- installation(options[:installation], opts, need),
         base = base_opts(name, parsed, opts),
         :ok <- confirmed(subcommand, name, parsed, opts),
         {:ok, platform_opts, pending?} <- with_source(subcommand, parsed, base, opts),
         {:ok, message} <- run(subcommand, server, parsed, platform_opts, pending?) do
      {:ok, %{text: message, json: nil}}
    else
      {:ok, :not_confirmed} -> {:ok, %{text: "Nothing removed.", json: nil}}
      error -> error
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

  `opts` may name `:home` (`~/.ehos`), `:server` (the module whose `made?/1` is asked), `:env` and
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
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
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
          do: "--installation #{name} to make a new one",
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
           "#{home(opts)}. Make one with `ehosctl server up --installation #{up}`."}

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

  # The installations whose server's state is kept under `home`. A directory there that is no
  # installation's, as one an operator made for files of their own, holds no `server.tfvars.json`
  # and is not listed.
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

  # `down` names the installation and asks before anything else, a download included; one never
  # made was refused before (`installation/3`).
  defp confirmed(:down, name, parsed, opts) do
    confirm = Keyword.get(opts, :confirm, &confirm/1)

    cond do
      parsed.flags[:yes] ->
        :ok

      confirm.(
        "Remove the server of the installation #{name}, ehos-#{name}, its network and " <>
            "everything on it?"
      ) ->
        :ok

      true ->
        {:ok, :not_confirmed}
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
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
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

  defp platform({:ok, message}), do: {:ok, message}
  defp platform({:error, message}), do: {:error, :failed, message}

  # A line may hold what the server printed, as cloud-init's errors (#165).
  defp progress(line), do: IO.puts(:stderr, "==> " <> Ehosctl.Output.shown_lines(line))

  # A question with no answer, as a script's stdin gives, is a no.
  defp confirm(question) do
    case IO.gets(:stdio, question <> " [y/N] ") do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      _eof -> false
    end
  end
end
