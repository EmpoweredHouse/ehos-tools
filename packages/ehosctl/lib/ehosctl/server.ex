defmodule Ehosctl.Server do
  @moduledoc """
  `ehosctl server up | down | status | tunnel`: makes, reaches, reads and removes the server under
  an installation, in Oracle Cloud, AWS or GCP (eh-os D-77, D-83), with `EhosPlatform.Server`
  run through `Ehosctl.PlatformRunner` at the tool versions EHOS is tested with (T-13).

  The installation is the one `--installation` names, else `EHOSCTL_INSTALLATION`, else the
  current one, else `trial` (T-13), and its server's files are in `~/.ehos/<name>/`, as
  `mix ehos.server` keeps them, so a server made with Mix is read as it is. The OpenTofu modules
  come from an EHOS release (`Ehosctl.ServerRelease`), never a checkout.

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

    with {:ok, name} <- installation(options[:installation], opts),
         base = base_opts(name, parsed, opts),
         :ok <- confirmed(subcommand, server, name, parsed, base, opts),
         {:ok, platform_opts, pending?} <- with_source(subcommand, server, parsed, base, opts),
         {:ok, message} <- run(subcommand, server, parsed, platform_opts, pending?) do
      {:ok, %{text: message, json: nil}}
    else
      {:ok, :not_confirmed} -> {:ok, %{text: "Nothing removed.", json: nil}}
      error -> error
    end
  end

  @doc """
  The installation's name: `flag`, else `EHOSCTL_INSTALLATION`, else the current installation,
  else `trial` (T-13). It must be one the OpenTofu module takes as well as T-07's.
  """
  @spec installation(String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, Ehosctl.Output.kind(), String.t()}
  def installation(flag, opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env) end)
    from_env = if env["EHOSCTL_INSTALLATION"] not in [nil, ""], do: env["EHOSCTL_INSTALLATION"]

    with {:ok, config} <- current(flag || from_env, config_dir) do
      name = flag || from_env || config || "trial"

      if Platform.valid_name?(name),
        do: {:ok, name},
        else:
          {:error, :invalid,
           "#{Ehosctl.Refusal.shown(name)} cannot name a server: #{Platform.name_rule()}"}
    end
  end

  # The current installation, read only when no name was given.
  defp current(nil, config_dir) do
    case Config.read(config_dir) do
      {:ok, config} ->
        {:ok, config.current}

      {:error, kind, message} ->
        {:error, kind,
         message <> "; or name the installation with --installation or EHOSCTL_INSTALLATION"}
    end
  end

  defp current(_named, _config_dir), do: {:ok, nil}

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
      name_option: "--installation"
    )
    |> Keyword.put(:passphrase, passphrase(opts))
  end

  # `down` names the installation and asks before anything else, a download included; a server
  # that was never made is left for `EhosPlatform.Server` to say so.
  defp confirmed(:down, server, name, parsed, base, opts) do
    confirm = Keyword.get(opts, :confirm, &confirm/1)

    cond do
      parsed.flags[:yes] or not server.made?(base) ->
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

  defp confirmed(_subcommand, _server, _name, _parsed, _base, _opts), do: :ok

  # The modules from the release (`Ehosctl.ServerRelease`), and whether `up` downloaded one it
  # keeps only once it has succeeded.
  defp with_source(subcommand, server, parsed, base, opts) do
    dir = Platform.dir(base)

    cond do
      # Closing a tunnel, or a command on a server not made yet, needs no modules: the latter
      # fails saying how to make one, before OpenTofu would run.
      subcommand == :tunnel and parsed.flags[:close] ->
        {:ok, base, false}

      subcommand != :up and not server.made?(base) ->
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

  # A release `up` downloaded is kept once `up` has made the server from it, and dropped otherwise.
  defp run(:up, server, _parsed, platform_opts, pending?) do
    dir = Platform.dir(platform_opts)
    result = platform(server.up(platform_opts))

    cond do
      not pending? -> result
      match?({:ok, _}, result) -> with(:ok <- ServerRelease.keep(dir), do: result)
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

  defp platform({:ok, message}), do: {:ok, message}
  defp platform({:error, message}), do: {:error, :failed, message}

  defp progress(line), do: IO.puts(:stderr, "==> " <> line)

  # A question with no answer, as a script's stdin gives, is a no.
  defp confirm(question) do
    case IO.gets(:stdio, question <> " [y/N] ") do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      _eof -> false
    end
  end
end
