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
         {:ok, platform_opts} <- platform_opts(subcommand, name, parsed, opts),
         {:ok, message} <- run(subcommand, server, name, parsed, platform_opts, opts) do
      {:ok, %{text: message, json: nil}}
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
    with {:ok, config} <- Config.read(config_dir), do: {:ok, config.current}
  end

  defp current(_named, _config_dir), do: {:ok, nil}

  defp platform_opts(subcommand, name, parsed, opts) do
    options = parsed.options
    home = Keyword.get(opts, :home, "~/.ehos")
    dir = Platform.dir(home: home, name: name)
    server = Keyword.get(opts, :server, Platform)

    base =
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
      |> then(fn base ->
        case Keyword.fetch(opts, :passphrase) do
          {:ok, passphrase} -> Keyword.put(base, :passphrase, passphrase)
          :error -> base
        end
      end)

    cond do
      # Closing a tunnel, or a command on a server not made yet, needs no modules: the latter
      # fails saying how to make one, before OpenTofu would run.
      subcommand == :tunnel and parsed.flags[:close] ->
        {:ok, base}

      subcommand != :up and not server.made?(base) ->
        {:ok, base}

      true ->
        command = if subcommand == :up, do: :up, else: :other

        with {:ok, source, _version} <-
               ServerRelease.source(dir, options[:version], command, opts),
             do: {:ok, Keyword.put(base, :source, source)}
    end
  end

  defp run(:up, server, _name, _parsed, platform_opts, _opts),
    do: platform(server.up(platform_opts))

  defp run(:tunnel, server, _name, parsed, platform_opts, _opts) do
    if parsed.flags[:close],
      do: platform(server.close_tunnel(platform_opts)),
      else: platform(server.tunnel(platform_opts))
  end

  defp run(:status, server, _name, _parsed, platform_opts, _opts),
    do: platform(server.status(platform_opts))

  defp run(:down, server, name, parsed, platform_opts, opts) do
    confirm = Keyword.get(opts, :confirm, &confirm/1)

    if parsed.flags[:yes] or
         confirm.(
           "Remove the server of the installation #{name}, ehos-#{name}, its network " <>
             "and everything on it?"
         ),
       do: platform(server.down(platform_opts)),
       else: {:ok, "Nothing removed."}
  end

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
