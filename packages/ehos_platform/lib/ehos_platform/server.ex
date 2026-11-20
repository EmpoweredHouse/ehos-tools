defmodule EhosPlatform.Server do
  @moduledoc """
  Makes, reaches and removes the server under an installation (D-77), behind `ehosctl server` and
  `mix ehos.server`.

  The server is described by its provider's OpenTofu module, `deploy/tofu/<provider>` in the
  `EhosPlatform.Source` the caller gives as `:source`: Oracle Cloud, AWS or GCP (D-83,
  `EhosPlatform.Server.Provider`), and k3s is installed on it by the shared cloud-init document on
  the first boot. Every command but `close_tunnel/1` reads the module's state, and is given a
  source; without one, it raises. Each installation has a directory outside the repository,
  `~/.ehos/<name>`, readable by its owner alone, which holds:

    * `installation.json`, where `up` made the server: the provider, the account and the region
      (`EhosPlatform.Server.Provider.place/2`), written just before the first apply. `up` refuses
      another place, which would leave this server running where no command reaches it. An
      installation made before D-83 has none and is Oracle's, until `up` writes one with its key.
      It also holds `ssh_key`, the path of the private SSH key `up` last put on the server, never
      the key itself, from `~/` when it is under the operator's home (`portable_path/2`); every
      later command logs in with it unless given another (ehos-tools#656). An installation `up`
      has not run on since has none, and its commands log in with `~/.ssh/ehos_oci`; `up` refuses
      to put that key on a server in place of another;
    * `server.tfvars.json`, the module's variables, none of them secret: the provider's account,
      region and profile, the server's size once one was given (D-84), the public SSH key, and
      the addresses SSH is admitted from;
    * `terraform.tfstate`, OpenTofu's state, encrypted under the passphrase in
      `EHOS_STATE_PASSPHRASE`, which OpenTofu gets in its environment and never on a command line;
    * `known_hosts`, the server's SSH host key, recorded when `up` first reaches it;
    * `kubeconfig`, written by `tunnel`, whose context `ehos-<name>` reaches the API server through
      an SSH tunnel. Port 6443 is never open to the internet.

  Every `tofu` and `ssh` call goes through `EhosPlatform.CommandRunner`, the environment is read
  through `EhosPlatform.Env`, a wait goes through `EhosPlatform.Clock`, and this machine's public
  address is asked of `EhosPlatform.PublicAddress` (T-20).
  """

  alias EhosPlatform.ClockImpl
  alias EhosPlatform.CommandRunner
  alias EhosPlatform.CommandRunnerImpl
  alias EhosPlatform.Env
  alias EhosPlatform.PublicAddressImpl
  alias EhosPlatform.Report
  alias EhosPlatform.Secret
  alias EhosPlatform.Server.Provider
  alias EhosPlatform.Shell
  alias EhosPlatform.Source

  @default_name "trial"
  # The private key a command logs in with when it is given none and `up` recorded none.
  @default_key "~/.ssh/ehos_oci"
  @default_port 16_443
  # How long an SSH control command (`-O check`, `-O exit`) may take (eh-os#291).
  @control_timeout 5_000
  @user "ubuntu"
  # The widest block `--ssh-from` admits. eh-os's server modules refuse a wider one too, from the
  # release with eh-os#1487 on; an earlier release's modules, which `:source` can name, do not.
  @widest_ssh_prefix 16

  @enforce_keys [:name, :provider, :dir, :passphrase, :ssh_key, :user_home, :runner, :progress]
  # How the operator runs these commands, for the sentences that name them, unless the caller says.
  @command "mix ehos.server"
  @name_option "--name"

  defstruct @enforce_keys ++
              [
                :place,
                :source,
                clock: ClockImpl,
                provider_env: [],
                key_recorded: false,
                command: @command,
                name_option: @name_option,
                name_in_commands: false
              ]

  @typedoc "One installation's server, and how to reach it."
  @type t :: %__MODULE__{
          name: String.t(),
          provider: Provider.t() | nil,
          provider_env: [{String.t(), String.t() | nil}],
          source: Source.t() | nil,
          place: %{String.t() => String.t()} | nil,
          dir: Path.t(),
          passphrase: String.t(),
          ssh_key: Path.t(),
          user_home: Path.t(),
          key_recorded: boolean(),
          runner: module(),
          progress: (Report.event() -> any()),
          clock: module(),
          command: String.t(),
          name_option: String.t(),
          name_in_commands: boolean()
        }

  @typedoc """
  The outcome of a command: `{:ok, report}` saying what was done, as the parts of an
  `EhosPlatform.Report`, or `{:error, message}` saying why it was not, a sentence an operator can
  act on.
  """
  @type result :: {:ok, Report.t()} | {:error, String.t()}

  @doc """
  Creates the installation's server, or brings it in line with the module, and waits until its
  first boot has installed k3s. The report names the state passphrase, the encrypted state and
  the SSH key in `secrets`, new when the apply changed the server.

  ## Options

    * `:name` — the installation. Defaults to `#{@default_name}`.
    * `:home` — where installations are kept. Defaults to `~/.ehos`. A path from `~/`, in this
      option, `:ssh_key` or `:oci_config`, is under the operator's home directory: `HOME` when it
      is an absolute path a shell would give, else the system's (`EhosPlatform.Env.home/1`).
    * `:passphrase` — encrypts OpenTofu's state. Defaults to `EHOS_STATE_PASSPHRASE`.
    * `:source` — the `EhosPlatform.Source` whose `deploy/tofu` describes the server (required).
    * `:ssh_key` — the private key the operator logs in with; its `.pub` beside it is put on the
      server, and `up` records its path in `installation.json`. Defaults to the key recorded
      there, else `~/.ssh/ehos_oci`.
    * `:provider` — `"oci"`, `"aws"` or `"gcp"`. Defaults to the one `up` made the server on; a
      server not made yet has none, and `up` refuses to choose one for the operator. An
      installation stays where it was made: another provider, account or region is refused, on
      every command.
    * `:oci_config`, `:oci_profile`, `:aws_profile`, `:gcp_project`, `:os_cloud` and `:region` — where the
      provider's account and region come from; see `EhosPlatform.Server.Provider.variables/3`.
    * `:ssh_from` — the IPv4 CIDR blocks SSH is admitted from, each read by `ssh_cidr/1`.
      Defaults to this machine's public addresses, asked of `:public_address`: every address it
      was seen to reach the internet from, since a network can leave through more than one
      (ehos-tools#157).
    * `:availability_domain` — which availability domain, from 0. Defaults to the one `up` used
      before, or 0.
    * `:ocpus` and `:memory_gb` on Oracle, `:instance_type` on AWS and GCP — the server's size
      (D-84); see `EhosPlatform.Server.Provider.size/3`. Each defaults to the one `up` used before,
      or the module's default. Changing it resizes the server in place, with a restart.
    * `:public_certificates` — `true` opens port 53 over UDP and TCP, for acme-dns on an
      installation with public certificates (eh-os D-158). Once given, `up` keeps it. A module
      that does not declare the variable, as one of a release before EHOS 0.27.0, would ignore it,
      and keep port 53 closed: `up` refuses it, before anything changes (ehos-tools#891).
    * `:release_option` — the option of `up` that names an EHOS release, for the sentences that
      name one (`--version` for `ehosctl`). None: they name the release in words.
    * `:replace` — let `up` remove or replace the server when the module says so. Defaults to
      false, and `up` then refuses such a plan without changing anything.
    * `:command` and `:name_option` — how the operator runs these commands, for the sentences
      that name them: `mix ehos.server` and `--name` unless given (`ehosctl server` and
      `--installation` for `ehosctl`).
    * `:name_in_commands` — whether a command those sentences suggest names the installation
      with `:name_option`, so that it reaches this server whatever the operator's default is.
      Defaults to false.
    * `:progress` — called with each `t:EhosPlatform.Report.event/0` of what is happening.
      Defaults to saying nothing.
    * `:runner`, `:env`, `:clock` and `:public_address` — the `EhosPlatform.CommandRunner`,
      `EhosPlatform.Env`, `EhosPlatform.Clock` and `EhosPlatform.PublicAddress` to use. Default to
      each one's implementation for this machine.
  """
  @spec up(keyword()) :: result()
  # Every path below is built from the operator's own options and home directory (`~/.ehos`, the
  # SSH key, `~/.oci/config`), in a Mix task they run on their machine; none comes from a request.
  # sobelow_skip ["Traversal.FileModule"]
  def up(opts \\ []) do
    with {:ok, server} <- setup(opts),
         :ok <- record_kept(server.dir),
         :ok <- require_provider(server),
         :ok <- port_53_known(server, opts),
         {:ok, public_key} <- read_public_key(server),
         :ok <- default_key_kept(server, opts),
         {:ok, provider_vars} <- Provider.variables(server.provider, opts, server.place),
         {:ok, size} <- Provider.size(server.provider, opts, recorded_vars(server)),
         {:ok, ssh_from} <- ssh_from(opts) do
      vars =
        server
        |> variables(provider_vars, public_key, ssh_from, opts)
        |> Map.merge(size)
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      replace? = Keyword.get(opts, :replace, false)

      with :ok <- same_place(server, vars),
           {:ok, before, changed?} <- apply_module(server, vars, ssh_from, replace?),
           {:ok, address} <- address(server),
           :ok <- moved(server, before, address),
           :ok <- carry_host_key(server, before, address),
           :ok <- wait_for_first_boot(server, address) do
        forget_previous_address(server)

        {:ok,
         %Report{
           outcome: "The server ehos-#{server.name} is up, with k3s.",
           values: [{"Address", address} | host_key_values(server, address)],
           next: [command(server, "tunnel")],
           secrets: up_secrets(server, changed?)
         }}
      end
    end
  end

  # The secrets an `up` relies on, new for the operator when the apply changed the server: its
  # state is then another one to copy, and the passphrase and key are what change it next.
  defp up_secrets(server, changed?) do
    [
      %Secret{kind: :state_passphrase, place: "EHOS_STATE_PASSPHRASE", new?: changed?},
      %Secret{
        kind: :encrypted_state,
        place: Path.join(server.dir, "terraform.tfstate"),
        new?: changed?
      },
      %Secret{kind: :ssh_key, place: server.ssh_key, new?: changed?}
    ]
  end

  @doc """
  Removes everything `up/1` made, closing the tunnel first, and forgets the server's host key and
  kubeconfig. On GCP it lifts the provider's deletion protection from the server first
  (`EhosPlatform.Server.Provider.lifted_before_removal?/1`). The state and the variables stay, so
  `up/1` can make the server again. Same options as `up/1`.
  """
  @spec down(keyword()) :: result()
  # sobelow_skip ["Traversal.FileModule"]
  def down(opts \\ []) do
    with {:ok, server} <- setup(opts),
         :ok <- require_vars(server) do
      _closed = close(server)

      with :ok <- init(server),
           :ok <- scope_held(server),
           {:ok, lifted} <- lift_protection(server),
           :ok <- removing(server),
           :ok <-
             server
             |> tofu(
               ["destroy", "-input=false", "-auto-approve" | var_file(server)],
               :unprotected
             )
             |> said_unprotected(server, lifted, :down) do
        forget_files(server)

        {:ok,
         %Report{
           outcome: "The server ehos-#{server.name} and everything made with it are removed."
         }}
      end
    end
  end

  @doc """
  Opens an SSH tunnel from `127.0.0.1:<port>` on this machine to the server's API server, in the
  background, and writes the installation's `kubeconfig` with a context `ehos-<name>` pointing
  at it. A tunnel already open is kept. Same options as `up/1`, and `:port`, which defaults to the
  port this installation's open tunnel holds, else the first from #{@default_port} that no other
  installation's open tunnel holds. The report names the SSH key and the kubeconfig in `secrets`,
  the kubeconfig new when its client certificate and key differ from those in the file before.
  """
  @spec tunnel(keyword()) :: result()
  def tunnel(opts \\ []) do
    with {:ok, server} <- setup(opts),
         port = Keyword.get_lazy(opts, :port, fn -> default_port(server) end),
         :ok <- require_vars(server),
         :ok <- warn_other_key(server),
         :ok <- init(server),
         {:ok, address} <- refreshed_address(server),
         :ok <- open(server, address, port),
         {:ok, new?} <- write_kubeconfig(server, address, port) do
      kubeconfig = kubeconfig_path(server)

      {:ok,
       %Report{
         outcome: "The tunnel to the API server of ehos-#{server.name} is open.",
         values: [{"Address", "127.0.0.1:#{port}"}, {"Context", context(server)}],
         next: [
           "kubectl --kubeconfig #{Shell.word(kubeconfig)} --context #{context(server)} get nodes",
           command(server, "tunnel --close")
         ],
         secrets: [
           %Secret{kind: :ssh_key, place: server.ssh_key},
           %Secret{kind: :kubeconfig, place: kubeconfig, new?: new?}
         ]
       }}
    end
  end

  @doc "Closes the tunnel `tunnel/1` opened. Same options as `up/1`."
  @spec close_tunnel(keyword()) :: result()
  def close_tunnel(opts \\ []) do
    with {:ok, server} <- setup(opts) do
      case close(server) do
        :ok ->
          {:ok, %Report{outcome: "The tunnel to ehos-#{server.name} is closed."}}

        :not_open ->
          {:ok, %Report{outcome: "No tunnel to ehos-#{server.name} is open.", ending: :unchanged}}

        :timeout ->
          {:error, wedged(server)}
      end
    end
  end

  # The node's resources first, each on a line of its own, then a line `---`, then what the
  # first boot says, another `---`, and what Kubernetes says; the script ends 0 whatever
  # Kubernetes did.
  @status_script "printf 'cpus %s\\n' \"$(nproc)\"; " <>
                   "awk '/^(MemTotal|MemAvailable):/ {print $1, $2}' /proc/meminfo; " <>
                   "printf 'load %s\\n' \"$(cut -d' ' -f1-3 /proc/loadavg)\"; echo ---; " <>
                   "cloud-init status; echo ---; " <>
                   "sudo k3s kubectl get nodes -o wide 2>&1 || echo 'Kubernetes did not answer.'"

  @doc """
  The server's address, its CPUs, memory and load, how its first boot ended, and its Kubernetes
  node, read over SSH. The node's resources come from `/proc`, before Kubernetes is asked, so
  they are reported when k3s or EHOS is stopped (D-87); a Kubernetes that does not answer is said
  so. Same options as `up/1`.
  """
  @spec status(keyword()) :: result()
  def status(opts \\ []) do
    with {:ok, server} <- setup(opts),
         :ok <- require_vars(server),
         :ok <- warn_other_key(server),
         :ok <- init(server),
         {:ok, address} <- refreshed_address(server) do
      case ssh(server, address, [@status_script]) do
        {output, 0} ->
          {resources, tool_output} = status_report(output)

          {:ok,
           %Report{
             outcome: "The server ehos-#{server.name} answered.",
             values: [{"Address", address} | resources],
             tool_output: tool_output
           }}

        {output, 255} ->
          {:error, "`ssh` could not reach #{address}:\n" <> output <> ssh_hint(server, output)}

        result ->
          failure("ssh", result)
      end
    end
  end

  @doc ~S"""
  What `status/1`'s script printed: the node's resources as labelled values, and what cloud-init
  and Kubernetes printed, each with the command that printed it. Output in another form is
  returned whole, as the script's.

      iex> EhosPlatform.Server.status_report(
      ...>   "cpus 2\nMemTotal: 12249180\nMemAvailable: 10276344\nload 0.15 0.10 0.05\n---\n" <>
      ...>     "status: done\n---\nNAME STATUS\n"
      ...> )
      {[{"CPU", "2, load 0.15 0.10 0.05 (1, 5 and 15 minutes)"},
        {"Memory", "9.8 GiB available of 11.7 GiB"}],
       [{"cloud-init status", "status: done\n"}, {"kubectl get nodes", "NAME STATUS\n"}]}
  """
  @spec status_report(String.t()) :: {[{String.t(), String.t()}], [{String.t(), String.t()}]}
  def status_report(output) do
    case String.split(output, ~r/^---\n/m, parts: 3) do
      [head, boot, nodes] ->
        {resources(head), [{"cloud-init status", boot}, {"kubectl get nodes", nodes}]}

      _other ->
        {[], [{"the status script", output}]}
    end
  end

  defp resources(head) do
    read =
      for line <- String.split(head, "\n", trim: true),
          [key | values] <- [String.split(line)],
          into: %{},
          do: {key, values}

    cpu =
      case {read["cpus"], read["load"]} do
        {[cpus], [_, _, _] = load} ->
          "#{cpus}, load #{Enum.join(load, " ")} (1, 5 and 15 minutes)"

        _unread ->
          "not read"
      end

    memory =
      with [total] <- read["MemTotal:"],
           [available] <- read["MemAvailable:"],
           {total, ""} <- Integer.parse(total),
           {available, ""} <- Integer.parse(available) do
        "#{gib(available)} GiB available of #{gib(total)} GiB"
      else
        _unread -> "not read"
      end

    [{"CPU", cpu}, {"Memory", memory}]
  end

  # /proc/meminfo counts in kB, which are KiB.
  defp gib(kib), do: :erlang.float_to_binary(kib / 1_048_576, decimals: 1)

  @doc """
  Runs `command`, a shell line, on the server over SSH as `status/1` does, and returns what it
  printed and its exit status, 255 when SSH itself failed. For `mix ehos.server.check`, which
  restarts the server and waits for it to answer again (eh-os#259). `command` runs in the server's
  shell: callers pass fixed commands, never a value from elsewhere. Same options as `up/1`, and
  `:address`, the server's address when the caller knows it, which spares reading OpenTofu's
  state on every call of a poll.
  """
  @spec remote(keyword(), String.t()) ::
          {:ok, CommandRunner.result()} | {:error, String.t()}
  def remote(opts, command) do
    with {:ok, server} <- setup(opts),
         :ok <- require_vars(server),
         {:ok, address} <- known_address(server, opts[:address]) do
      case ssh(server, address, [command]) do
        {output, status} when is_integer(status) -> {:ok, {output, status}}
        result -> failure("ssh", result)
      end
    end
  end

  defp known_address(server, nil), do: with(:ok <- init(server), do: address(server))
  defp known_address(_server, address), do: {:ok, address}

  @doc """
  Whether `name` may name an installation: 2 to 16 lowercase letters, digits and hyphens,
  starting with a letter, as the OpenTofu module's variable requires.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and name =~ ~r/\A[a-z][a-z0-9-]{0,14}[a-z0-9]\z/

  @doc """
  Whether `passphrase` may encrypt an installation's state: at least 16 characters.

      iex> EhosPlatform.Server.valid_passphrase?("correct horse battery")
      true

      iex> EhosPlatform.Server.valid_passphrase?(nil)
      false
  """
  @spec valid_passphrase?(term()) :: boolean()
  def valid_passphrase?(passphrase), do: is_binary(passphrase) and String.length(passphrase) >= 16

  @doc "Says what `valid_name?/1` requires."
  @spec name_rule() :: String.t()
  def name_rule, do: "The installation's name is 2 to 16 lowercase letters, digits and hyphens"

  @doc """
  The installation's directory, `<home>/<name>`, from the options of `up/1`. A `:home` under `~`,
  as the default `~/.ehos` is, is under the operator's home directory (`EhosPlatform.Env.home/1`).

      iex> EhosPlatform.Server.dir(home: "/srv/ehos", name: "check")
      "/srv/ehos/check"
  """
  @spec dir(keyword()) :: Path.t()
  def dir(opts) do
    opts
    |> Keyword.get(:home, "~/.ehos")
    |> Env.expand(opts)
    |> Path.join(Keyword.get(opts, :name, @default_name))
  end

  @doc """
  Whether `up/1` would make the server in a cloud the operator named: `:ok` for an installation that
  records its provider, or when `:provider` names one, and `up/1`'s refusal otherwise (eh-os D-126),
  as `{:error, kind, message}`. The kind is `:invalid` for what the command line can change (the
  name, no provider, another provider than the recorded one) and `:failed` for an installation's
  record that cannot be read (ehos-tools#345). Reads only the installation's files, so a caller can
  refuse before it downloads anything. Takes `:name`, `:home` and `:provider`, as `up/1` does.
  """
  @spec provider_named(keyword()) :: :ok | {:error, :invalid | :failed, String.t()}
  def provider_named(opts) do
    name = Keyword.get(opts, :name, @default_name)
    dir = dir(opts)

    with {:name, true} <- {:name, valid_name?(name)},
         {:place, {:ok, place}} <- {:place, recorded_place(dir)},
         {:place, :ok} <- {:place, record_kept(dir)},
         {:ok, provider} <- provider(place, dir, name, opts),
         :ok <- require_provider(%{provider: provider, name: name}) do
      :ok
    else
      {:name, false} -> {:error, :invalid, name_rule()}
      {:place, {:error, message}} -> {:error, :failed, message}
      {:error, message} -> {:error, :invalid, message}
    end
  end

  @doc """
  What the installation in `dir` is, for the chart's `installation` value (D-90): `name`, and what
  `up` recorded of it, its `provider` and `region` from `installation.json` and its `size` from
  the variables, in the provider's own terms (D-84). A size `up` was not given is the module's
  default, which is not recorded and is left out; the nodes' capacity shows it.
  """
  @spec description(Path.t(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def description(dir, name) do
    with {:ok, place} <- recorded_place(dir) do
      vars = recorded_vars(%{dir: dir})

      described =
        case place do
          %{"provider" => provider} ->
            %{"provider" => provider, "region" => place["region"], "size" => size(provider, vars)}

          nil ->
            %{}
        end

      {:ok,
       described
       |> Map.put("name", name)
       |> Map.reject(fn {_key, value} -> value in [nil, ""] end)}
    end
  end

  defp size("oci", vars) do
    [{vars["ocpus"], "OCPUs"}, {vars["memory_gbs"], "GB"}]
    |> Enum.reject(fn {amount, _unit} -> is_nil(amount) end)
    |> Enum.map_join(", ", fn {amount, unit} -> "#{amount} #{unit}" end)
  end

  defp size("aws", vars), do: vars["instance_type"]
  defp size("gcp", vars), do: vars["machine_type"]
  defp size("ovh", vars), do: vars["flavor_name"]
  defp size(_provider, _vars), do: nil

  @doc """
  Whether `up/1` made the installation, so `down/1` has something to remove: its variables were
  kept, which `up/1` does only after it recorded where the server is, or it is an Oracle one made
  before D-83, with its variables and a state. Variables alone, as an older `up` that stopped before
  anything was made left them, are not an installation (ehos-tools#345). A record that cannot be
  read counts as one, so the command that reads it says why. Same options as `up/1`.
  """
  @spec made?(keyword()) :: boolean()
  # The installation's directory is the operator's own, under `~/.ehos`.
  # sobelow_skip ["Traversal.FileModule"]
  def made?(opts) do
    dir = dir(opts)

    # One whose record was lost still is, so its commands say to restore the record.
    File.exists?(vars_path(%{dir: dir})) and
      (recorded_place(dir) != {:ok, nil} or record_kept(dir) != :ok)
  end

  defp setup(opts) do
    check_options!(opts)
    name = Keyword.get(opts, :name, @default_name)

    passphrase = passphrase(opts)

    cond do
      not valid_name?(name) ->
        {:error, name_rule()}

      not valid_passphrase?(passphrase) ->
        {:error,
         "Set EHOS_STATE_PASSPHRASE to the passphrase of this installation's state, at least 16 " <>
           "characters. It encrypts OpenTofu's state (D-77); keep it where you keep passwords"}

      true ->
        dir = dir(opts)
        user_home = Env.home(opts)

        with :ok <- given_key(opts[:ssh_key]),
             {:ok, place} <- recorded_place(dir),
             {:ok, provider} <- provider(place, dir, name, opts),
             :ok <- same_options(place, name, opts) do
          {:ok,
           %__MODULE__{
             name: name,
             provider: provider,
             # What OpenTofu's environment takes out or is handed, from the same options the
             # module's variables come from, so the credentials checked are the ones it uses.
             provider_env: if(provider, do: Provider.env(provider, opts), else: []),
             place: place,
             dir: dir,
             passphrase: passphrase,
             ssh_key:
               Env.expand_home(
                 opts[:ssh_key] || recorded_key(place) || @default_key,
                 user_home
               ),
             user_home: user_home,
             # Taken from the record, not given: a key that is not here was made elsewhere.
             key_recorded: opts[:ssh_key] == nil and recorded_key(place) != nil,
             source: Keyword.get(opts, :source),
             runner: Keyword.get(opts, :runner, CommandRunnerImpl),
             progress: Keyword.get(opts, :progress, fn _event -> :ok end),
             clock: Keyword.get(opts, :clock, ClockImpl),
             command: Keyword.get(opts, :command, @command),
             name_option: Keyword.get(opts, :name_option, @name_option),
             name_in_commands: Keyword.get(opts, :name_in_commands, false)
           }}
        end
    end
  end

  # `up` records the key it is given, and every command reads it back by `key_kept/2`'s rule.
  defp given_key(key) when is_binary(key) do
    if Shell.printable?(key),
      do: :ok,
      else:
        {:error,
         "The path --ssh-key gives holds a control or format character, or is not UTF-8. Give " <>
           "the path of the private key as a terminal shows it"}
  end

  defp given_key(_none), do: :ok

  # Options that took a function until T-20 made each a module. A caller that still gives one
  # would have it ignored, and wait for real or ask the network from its tests, so it is refused
  # by name.
  @replaced [
    sleep: ":clock, a module that implements EhosPlatform.Clock",
    detect_address: ":public_address, a module that implements EhosPlatform.PublicAddress"
  ]

  @doc false
  # Raises `ArgumentError`, before anything runs, when `opts` gives one of the options `replaced`
  # names, saying what replaced it, or an `:env` that is not a module (`EhosPlatform.Env.from/1`),
  # so a bad `:env` read only on some paths fails on all of them.
  @spec check_options!(keyword(), [atom()]) :: :ok
  def check_options!(opts, replaced \\ Keyword.keys(@replaced)) do
    case Enum.find(replaced, &Keyword.has_key?(opts, &1)) do
      nil ->
        _env = Env.from(opts)
        :ok

      key ->
        raise ArgumentError,
              "#{inspect(key)} is no longer taken; give #{Keyword.fetch!(@replaced, key)}"
    end
  end

  @doc """
  The passphrase of the installation's state: `opts[:passphrase]`, else `EHOS_STATE_PASSPHRASE`
  from `opts[:env]`'s `EhosPlatform.Env`. `nil` when neither is set; `valid_passphrase?/1` says
  whether it will do.
  """
  @spec passphrase(keyword()) :: String.t() | nil
  def passphrase(opts) do
    Keyword.get_lazy(opts, :passphrase, fn ->
      Env.from(opts).get("EHOS_STATE_PASSPHRASE")
    end)
  end

  # Where `up` made the server, or, for an installation made before D-83, Oracle with its
  # variables: none of those has an installation.json, and every one has a tenancy and a state. A
  # first `up` that failed before anything was made left variables but no state, and binds
  # nothing. A file that cannot be read is refused rather than guessed at, since a wrong provider
  # would run another module against this state.
  # sobelow_skip ["Traversal.FileModule"]
  defp recorded_place(dir) do
    path = Path.join(dir, "installation.json")

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"provider" => provider} = place} when is_binary(provider) ->
            key_kept(place, path)

          _other ->
            {:error, "#{path} cannot be read as an installation's place; restore it"}
        end

      {:error, :enoent} ->
        with true <- File.exists?(Path.join(dir, "terraform.tfstate")),
             {:ok, contents} <- File.read(Path.join(dir, "server.tfvars.json")),
             {:ok, %{"tenancy_ocid" => _} = vars} <- Jason.decode(contents) do
          {:ok, Provider.place(:oci, vars)}
        else
          _none -> {:ok, nil}
        end

      {:error, reason} ->
        {:error, "#{path} cannot be read: #{:file.format_error(reason)}"}
    end
  end

  # A recorded key is a path as `up` writes it, absolute or from `~/`, without `..`, and with
  # nothing a terminal acts on, since SSH is given it and messages show it: anything else was not
  # written by `up`.
  defp key_kept(%{"ssh_key" => key} = place, path) do
    if is_binary(key) and key_path?(key),
      do: {:ok, place},
      else: {:error, "#{path} holds an ssh_key that is not a path; restore it"}
  end

  defp key_kept(place, _path), do: {:ok, place}

  defp key_path?(key) do
    Shell.printable?(key) and (String.starts_with?(key, "/") or String.starts_with?(key, "~/")) and
      ".." not in Path.split(key)
  end

  # An installation stays on the provider it was made on; one not made yet takes the one asked, and
  # has none when none was asked: no cloud is chosen for the operator.
  defp provider(place, dir, name, opts), do: provider(place, dir, name, opts[:provider], opts)

  defp provider(nil, _dir, _name, nil, _opts), do: {:ok, nil}
  defp provider(nil, _dir, _name, asked, _opts), do: Provider.parse(asked)

  defp provider(%{"provider" => recorded}, _dir, _name, asked, _opts)
       when asked in [nil, recorded],
       do: Provider.parse(recorded)

  defp provider(%{"provider" => recorded}, dir, name, asked, opts) do
    name_option = Keyword.get(opts, :name_option, @name_option)
    down = suggested(Keyword.put(opts, :name, name), "down")

    with {:ok, _asked} <- Provider.parse(asked) do
      {:error,
       "ehos-#{name} is on #{recorded}, not #{asked}. Choose another #{name_option} for a " <>
         "server on #{asked}; once #{down} has removed this one, #{dir} can be deleted"}
    end
  end

  # A region or project given on any command is held to the recorded one: `down` or `status`
  # with another would otherwise read as if it were this installation's.
  defp same_options(nil, _name, _opts), do: :ok

  defp same_options(place, name, opts) do
    given = %{"region" => opts[:region], "project" => opts[:gcp_project]}

    case for(
           {key, value} <- given,
           value != nil,
           Map.has_key?(place, key),
           place[key] != value,
           do: "#{key} #{place[key]} → #{value}"
         ) do
      [] -> :ok
      moved -> {:error, moved_message(name, moved, Keyword.get(opts, :name_option, @name_option))}
    end
  end

  # Another account or region than the recorded one is another server (`Provider.identity/1`).
  defp same_place(server, vars) do
    case Provider.moved(server.provider, server.place, vars) do
      [] -> :ok
      moved -> {:error, moved_message(server.name, moved, server.name_option)}
    end
  end

  defp moved_message(name, moved, name_option) do
    "ehos-#{name} was made in another place than this asks (#{Enum.join(moved, ", ")}): that " <>
      "would make a second server and leave the first running where no command reaches it. " <>
      "Nothing was changed. Give the options it was made with (on Oracle, the profile in " <>
      "~/.oci/config it was made with), or choose another #{name_option}"
  end

  # A command the operator can run next, quoted, as they run these commands (`:command`), and
  # naming the installation when the caller asks (`:name_in_commands`): without it, the command
  # reaches whichever installation is the operator's default when they run it.
  defp suggested(opts, args) when is_list(opts) do
    suggested(
      %{
        command: Keyword.get(opts, :command, @command),
        name_option: Keyword.get(opts, :name_option, @name_option),
        name_in_commands: Keyword.get(opts, :name_in_commands, false),
        name: Keyword.get(opts, :name, @default_name)
      },
      args
    )
  end

  defp suggested(server, args), do: "`#{command(server, args)}`"

  # The same command, not quoted, for a report's `next`.
  defp command(server, args) do
    named = if server.name_in_commands, do: " #{server.name_option} #{server.name}", else: ""
    "#{server.command} #{args}#{named}"
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_public_key(server) do
    public = server.ssh_key <> ".pub"

    # An empty one is missing: `ssh-keygen -y` that failed leaves the file its redirect made.
    case File.read(public) do
      {:ok, key} ->
        case String.trim(key) do
          "" -> missing_key(server, "is empty")
          key -> public_key(public, key)
        end

      {:error, :enoent} ->
        missing_key(server, "is missing")

      {:error, reason} ->
        {:error, "#{public} cannot be read: #{:file.format_error(reason)}"}
    end
  end

  # What the provider puts on the server must be a key OpenSSH reads, `<type> <base64> [comment]`,
  # so that a stray file is not what the next login depends on.
  defp public_key(public, key) do
    if key =~ ~r/\A[a-z0-9@.-]+[ \t]+[A-Za-z0-9+\/]+={0,2}([ \t]+[^\n]*)?\z/i,
      do: {:ok, key},
      else:
        {:error,
         "#{public} does not hold an SSH public key: a type and a key in base64, such as " <>
           "`ssh-ed25519 AAAAC3Nza…`"}
  end

  # An installation made before `up` recorded its key may have been made with another than the
  # default: `up` given none would put the default on the server in its place, and on GCP that is
  # the one key the server takes (ehos-tools#656). A key given or recorded is the operator's
  # choice, and so is the default on a server `--replace` makes again or none was made on yet.
  defp default_key_kept(server, opts) do
    if opts[:ssh_key] == nil and not server.key_recorded and
         not Keyword.get(opts, :replace, false) and
         has_key?(server) and other_key?(server),
       do:
         {:error,
          "#{server.ssh_key}.pub is not the public key that `up` put on ehos-#{server.name}, and " <>
            "`up` would put it on the server in place of that one. Nothing was changed. " <>
            give_key() <> ", or this one to replace it"},
       else: :ok
  end

  # A private key alone has its public key written from it; `-t` would offer to replace it. The
  # file is written only once `ssh-keygen` succeeded, so a mistyped passphrase leaves no empty
  # one behind, and with `>|`, which a shell under `noclobber` still lets replace an empty one
  # (ehos-tools#571).
  defp missing_key(server, why) do
    key = Shell.word(server.ssh_key)

    remedy =
      if File.regular?(server.ssh_key),
        do:
          "Write it from the private key with " <>
            "`pub=$(ssh-keygen -y -f #{key}) && printf '%s\\n' \"$pub\" >| " <>
            "#{Shell.word(server.ssh_key <> ".pub")}`",
        else: make_key(server)

    {:error, "#{server.ssh_key}.pub #{why}. " <> remedy}
  end

  # A key `up` recorded and this machine lacks is on the server already: a new one would replace it.
  defp make_key(%{key_recorded: true} = server) do
    "The key #{server.ssh_key} that `up` recorded is not on this machine, and a new one would " <>
      "replace the server's: give the private key that `up` put on the server with `--ssh-key`"
  end

  # So is a key on a server made before `up` recorded keys, when the default is what is missing.
  defp make_key(server) do
    if server.ssh_key == Env.expand_home(@default_key, server.user_home) and has_key?(server),
      do:
        "The server has a key that `up` put on it before, and a new one would replace it: " <>
          "give the private key that `up` put on the server with `--ssh-key`",
      else: "Make the key with `ssh-keygen -t ed25519 -f #{Shell.word(server.ssh_key)}`"
  end

  # Whether `up` made the server with a public key: a state, and the key in its variables. A first
  # `up` that stopped before anything was made left variables but no state.
  # sobelow_skip ["Traversal.FileModule"]
  defp has_key?(server) do
    File.exists?(Path.join(server.dir, "terraform.tfstate")) and
      is_binary(recorded_vars(server)["ssh_public_key"])
  end

  defp ssh_from(opts) do
    case Keyword.get(opts, :ssh_from, []) do
      [] ->
        opts
        |> Keyword.get(:public_address, PublicAddressImpl)
        |> detect_addresses()
        |> detected()

      values ->
        ssh_cidrs(values, [])
    end
  end

  defp detected({:ok, addresses}), do: {:ok, Enum.map(addresses, &(&1 <> "/32"))}

  defp detected({:error, reason}),
    do: {:error, "This machine's public address is unknown (#{reason}); give it with --ssh-from"}

  # The same block given twice, as `192.0.2.1` and `192.0.2.1/32`, is admitted once, rather than
  # left to each module to collapse.
  defp ssh_cidrs([], cidrs), do: {:ok, cidrs |> Enum.reverse() |> Enum.uniq()}

  defp ssh_cidrs([value | rest], cidrs) do
    with {:ok, cidr} <- ssh_cidr(value), do: ssh_cidrs(rest, [cidr | cidrs])
  end

  @doc """
  Reads one `--ssh-from` value as the IPv4 CIDR block the provider's firewall admits SSH from, so a
  value every cloud would refuse is refused before OpenTofu plans anything (eh-os#260).

  A bare address is that address alone, `/32`. The block is refused when it is not IPv4 (no module
  gives the server an IPv6 address), when it is the whole internet (`/0`), when it is wider than
  `/16`, 65,536 addresses, and when it is not written as its network address, which AWS's provider
  refuses: `192.0.2.1/24` may mean the block or the address, so the refusal names both rather than
  guessing. A prefix length is written as a plain number: `/024` and `/+24` are refused.

  This check holds the floor for `up/1`. eh-os's server modules refuse a block wider than `/16`
  only from the release with eh-os#1487 on, so a module of an earlier release, which `:source` can
  name, does not.

      iex> EhosPlatform.Server.ssh_cidr("192.0.2.1")
      {:ok, "192.0.2.1/32"}

      iex> EhosPlatform.Server.ssh_cidr("192.0.2.0/24")
      {:ok, "192.0.2.0/24"}

      iex> {:error, message} = EhosPlatform.Server.ssh_cidr("192.0.2.1/24")
      iex> message =~ "192.0.2.0/24" and message =~ "192.0.2.1/32"
      true
  """
  @spec ssh_cidr(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def ssh_cidr(value) do
    {address, prefix} =
      case String.split(value, "/") do
        [address] -> {address, "32"}
        [address, prefix] -> {address, prefix}
        _more -> {value, nil}
      end

    with {:ok, ip} <- ipv4(value, address),
         {:ok, bits} <- prefix_length(value, prefix) do
      network = network_address(ip, bits)
      cidr = "#{:inet.ntoa(network)}/#{bits}"

      if network == ip do
        {:ok, cidr}
      else
        {:error,
         "--ssh-from #{value} has host bits set; give the block as #{cidr}, " <>
           "or the address alone as #{:inet.ntoa(ip)}/32"}
      end
    end
  end

  defp ipv4(value, address) do
    charlist = String.to_charlist(address)

    case {:inet.parse_ipv4strict_address(charlist), :inet.parse_ipv6strict_address(charlist)} do
      {{:ok, ip}, _ipv6} ->
        {:ok, ip}

      {_not_ipv4, {:ok, _ip}} ->
        {:error,
         "--ssh-from #{value} is IPv6; the server is reached over IPv4 alone, " <>
           "so give the IPv4 address SSH comes from"}

      _neither ->
        {:error,
         "--ssh-from #{value} is not an IPv4 address or CIDR block, " <>
           "such as 192.0.2.4 or 192.0.2.0/24"}
    end
  end

  defp prefix_length(value, prefix) do
    case prefix && Integer.parse(prefix) do
      {0, ""} ->
        {:error,
         "--ssh-from #{value} admits the whole internet; give the addresses SSH comes from"}

      {bits, ""} when bits in 1..32 ->
        written_prefix(value, prefix, bits)

      _other ->
        {:error,
         "--ssh-from #{value} is not an IPv4 address or CIDR block, " <>
           "such as 192.0.2.4 or 192.0.2.0/24"}
    end
  end

  # SSH is the one way to administer the server, so a block wider than a company's own network is
  # refused: `/1` would admit half of the internet (eh-os#1487).
  defp written_prefix(value, prefix, bits) do
    cond do
      prefix != Integer.to_string(bits) ->
        {:error, "--ssh-from #{value} writes its prefix length as #{prefix}; write it as #{bits}"}

      bits < @widest_ssh_prefix ->
        {:error,
         "--ssh-from #{value} is wider than /#{@widest_ssh_prefix}, 65,536 addresses; give the " <>
           "block your network leaves through, /#{@widest_ssh_prefix} or narrower"}

      true ->
        {:ok, bits}
    end
  end

  defp network_address({a, b, c, d}, bits) do
    <<address::32>> = <<a, b, c, d>>
    host = Bitwise.bsl(1, 32 - bits) - 1
    <<a, b, c, d>> = <<Bitwise.band(address, Bitwise.bnot(host))::32>>
    {a, b, c, d}
  end

  # Services that answer with the caller's IPv4 address and nothing else, run by different
  # companies, so one that is down or slow leaves the others.
  @address_services [
    "https://checkip.amazonaws.com",
    "https://api.ipify.org",
    "https://ipv4.icanhazip.com"
  ]

  # How many times each service is asked, each on a connection of its own.
  @address_asks 2

  @doc false
  # The addresses the server may see SSH come from, so only they are admitted. A network can
  # leave for the internet through more than one address, by connection or by destination
  # (ehos-tools#157), so each of several services is asked more than once, of `public_address`,
  # and every address seen is admitted, in the order first seen; an error only when no service
  # gave one, naming each one's. An ask that takes longer than `timeout_ms` is that service's
  # error, so a service that trickles its answer cannot hold `up`.
  @spec detect_addresses(module(), timeout()) :: {:ok, [String.t(), ...]} | {:error, String.t()}
  def detect_addresses(public_address, timeout_ms \\ 20_000) do
    asks = for service <- @address_services, _ask <- 1..@address_asks, do: service

    # All at once, so `timeout_ms` bounds the whole detection, whatever the machine's cores.
    answers =
      asks
      |> Task.async_stream(&{&1, ask(public_address, &1)},
        max_concurrency: length(asks),
        timeout: timeout_ms,
        on_timeout: :kill_task,
        zip_input_on_exit: true,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, answer} -> answer
        {:exit, {service, :timeout}} -> {service, {:error, "it did not answer in time"}}
        # A task killed from outside its ask, by a process linked to it, which `ask/2` cannot
        # catch: that service's failure too, its reason left out.
        {:exit, {service, _reason}} -> {service, {:error, "its ask failed"}}
      end)

    case for({_service, {:ok, address}} <- answers, uniq: true, do: address) do
      [] ->
        reasons =
          for {service, {:error, reason}} <- answers, uniq: true do
            "#{URI.parse(service).host}: #{reason}"
          end

        {:error, Enum.join(reasons, "; ")}

      addresses ->
        {:ok, addresses}
    end
  end

  # An ask that crashed is that service's failure, as one that returned an error is, caught in
  # its task, so that it neither stops the caller nor, through the task's link, kills one that
  # does not trap exits (ehos-tools#544). What it raised is left out: it can hold any term.
  defp ask(public_address, service) do
    public_address.ask(service)
  catch
    _kind, _reason -> {:error, "its ask failed"}
  end

  defp variables(server, provider_vars, public_key, ssh_from, opts) do
    Map.merge(provider_vars, %{
      name: server.name,
      # On AWS and GCP, which of the region's zones, in the provider's order.
      availability_domain:
        Keyword.get_lazy(opts, :availability_domain, fn ->
          previous(server, "availability_domain", 0)
        end),
      ssh_public_key: public_key,
      ssh_from: ssh_from
    })
    |> Map.merge(public_certificates(server, opts))
  end

  @no_source "OpenTofu runs on a source's modules: pass :source"

  # ehos-tools#891: OpenTofu only warns of a variable its module does not declare, so a module from
  # before EHOS 0.27.0 would be given `public_certificates`, keep port 53 closed, and `up` would succeed.
  defp port_53_known(server, opts) do
    cond do
      public_certificates(server, opts) == %{} ->
        :ok

      server.source == nil ->
        raise ArgumentError, @no_source

      Source.declares_variable?(
        server.source,
        Provider.name(server.provider),
        "public_certificates"
      ) ->
        :ok

      true ->
        {:error,
         "ehos-#{server.name} is not changed. Its OpenTofu modules cannot open port 53, which " <>
           "public certificates need: they come from an EHOS release before 0.27.0. " <>
           port_53_release(server, opts)}
    end
  end

  defp port_53_release(server, opts) do
    case Keyword.get(opts, :release_option) do
      nil ->
        "Run #{suggested(server, "up --public-certificates")} with the modules of EHOS 0.27.0 " <>
          "or later"

      option ->
        "Run #{suggested(server, "up --public-certificates #{option} <0.27.0 or later>")}"
    end
  end

  # eh-os D-158: given only when true, so a module from before the variable is not given one it
  # does not declare. Kept once given, as the availability domain is.
  defp public_certificates(server, opts) do
    if Keyword.get(opts, :public_certificates) == true or
         previous(server, "public_certificates", false) == true,
       do: %{public_certificates: true},
       else: %{}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_vars(server, vars, path) do
    with :ok <- File.mkdir_p(server.dir),
         :ok <- File.chmod(server.dir, 0o700),
         :ok <- File.write(path, Jason.encode_to_iodata!(vars, pretty: true)),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        {:error, "#{server.dir} cannot be written: #{:file.format_error(reason)}"}
    end
  end

  # A variable `up` wrote before, so running it again without the option keeps it: a different
  # availability domain is a different server.
  defp previous(server, key, default), do: Map.get(recorded_vars(server), key, default)

  # The variables the last `up` wrote, or none.
  # sobelow_skip ["Traversal.FileModule"]
  defp recorded_vars(server) do
    with {:ok, contents} <- File.read(vars_path(server)),
         {:ok, %{} = vars} <- Jason.decode(contents) do
      vars
    else
      _none -> %{}
    end
  end

  # D-84: a server that exists is resized in place, which every provider does by stopping and
  # starting it; its disk and its address stay. Said from the plan's own values: a plan that
  # replaces the server has been refused without `--replace` already, and one that makes it anew
  # resizes nothing.
  defp announce_resize(_server, []), do: :ok

  defp announce_resize(server, resized) do
    server.progress.(
      {:step,
       "Resizing ehos-#{server.name} (#{Enum.join(resized, ", ")}): the provider stops and " <>
         "starts it, and its disk and address stay"}
    )

    :ok
  end

  defp require_vars(server) do
    # Variables with no recorded provider are an older `up`'s that stopped before anything was made,
    # or files edited by hand: no cloud is assumed for them.
    # A command to copy names one provider: `aws|gcp` would be a pipeline in a shell.
    make =
      if server.place,
        do: suggested(server, "up"),
        else:
          suggested(server, "up --provider PROVIDER") <>
            ", PROVIDER one of #{Enum.join(Provider.names(), ", ")}"

    # A recorded place, not a provider named on this command: variables without one were never
    # made into a server, whatever --provider says (ehos-tools#345).
    cond do
      server.place != nil and File.exists?(vars_path(server)) ->
        :ok

      record_kept(server.dir) != :ok ->
        record_kept(server.dir)

      true ->
        {:error, "No installation #{server.name} in #{server.dir}. Make it with #{make}"}
    end
  end

  # Variables and a state with no record: `installation.json` was lost, not never written, since
  # `up` writes it before any apply. No command takes the place from its own options then: `up`
  # would plan in another account or region than the server's, and make one there beside it.
  # sobelow_skip ["Traversal.FileModule"]
  defp record_kept(dir) do
    if File.exists?(vars_path(%{dir: dir})) and File.exists?(Path.join(dir, "terraform.tfstate")) and
         recorded_place(dir) == {:ok, nil},
       do:
         {:error,
          "#{Path.join(dir, "installation.json")} is missing, though #{dir} holds a state: " <>
            "restore it from where it was kept, since it says which provider, account and " <>
            "region the server is in. Running `up` without it could make a server in another " <>
            "place than the first's"},
       else: :ok
  end

  defp require_provider(%{provider: nil} = server) do
    {:error,
     "Name the cloud to make ehos-#{server.name} in with --provider " <>
       "#{Enum.join(Provider.names(), ", ")}; EHOS does not choose one for you. The server " <>
       "stays there: every later command reads it from the installation"}
  end

  defp require_provider(_server), do: :ok

  defp init(server) do
    with :ok <- make_plugin_cache(server) do
      init_module(server)
    end
  end

  # Shared by every installation, so the provider is downloaded once; OpenTofu checks what it
  # takes from here against the lock file's hashes. Two commands must not run at once: OpenTofu's
  # cache is not safe for concurrent `init`, and neither are a tunnel's socket and record.
  # sobelow_skip ["Traversal.FileModule"]
  defp make_plugin_cache(server) do
    home = Path.dirname(server.dir)

    with :ok <- File.mkdir_p(plugin_cache(server)),
         :ok <- File.chmod(home, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, "#{home} cannot be written: #{:file.format_error(reason)}"}
    end
  end

  defp init_module(server) do
    tofu(server, [
      "init",
      "-input=false",
      "-reconfigure",
      "-lockfile=readonly",
      "-backend-config=path=#{Path.join(server.dir, "terraform.tfstate")}"
    ])
  end

  # The plan is read before it is applied. Changing a firewall rule or the admitted addresses is
  # what running `up` again is for; replacing or removing the server loses everything on it, and
  # Ampere capacity to make another may not be there, so that takes `replace`.
  #
  # The variables are planned from a file beside the installation's own, which replaces it only
  # once the apply is reached: whatever stops `up` before, a failure, a refusal, an exception or an
  # interrupt, leaves the recorded variables as they were, so the next `up` without options plans
  # what the server already is, its size included.
  # sobelow_skip ["Traversal.FileModule"]
  defp apply_module(server, vars, ssh_from, replace?) do
    plan = Path.join(server.dir, "up.tfplan")
    next = vars_path(server) <> ".next"

    try do
      prepare = fn -> prepare_apply(server, vars, ssh_from, replace?, plan, next) end

      with {:ok, planned} <- prepare.(),
           {:ok, lifted} <- unprotected(server, planned.deleted) do
        with {:ok, planned} <- if(lifted, do: prepare.(), else: {:ok, planned}),
             before = previous_address(server) || planned.before,
             :ok <- keep_previous_address(server, before),
             {:ok, replaced} <- record_key(server),
             :ok <- keep_vars(server, next),
             :ok <- run_apply(server, plan, planned.deleted) |> key_before(server, replaced) do
          {:ok, before, planned.changed?}
        end
        |> said_unprotected(server, lifted)
      end
    after
      _removed = File.rm(plan)
      _removed = File.rm(next)
    end
  end

  # A plan `--replace` allowed to remove the server is applied only once the provider's deletion
  # protection is lifted from it, which changes the state the plan was made on: once lifted, it is
  # made again, and whatever stops `up` after the lift says the server is unprotected.
  defp unprotected(server, removed) do
    if Provider.instance(server.provider) in removed,
      do: lift_protection(server),
      else: {:ok, false}
  end

  # ehos-tools#430: on GCP the module asks Compute Engine to refuse deleting the server, from its
  # console, gcloud or a `tofu destroy` run by hand alike, so `down` and `up --replace` lift that
  # protection before they remove it (`Provider.lifted_before_removal?/1`; on AWS the module's
  # `force_destroy` has the provider lift it). The lift is an apply on the server alone, planned
  # from the variables it was made with and `deletion_protection` false, and read before it runs:
  #
  #   * a server with no protection on in the state, as one made before the variable, one that is
  #     not there, or one whose protection was lifted already, has none to lift;
  #   * otherwise the plan may change that attribute of the server and nothing else, so the lift
  #     never removes, replaces or updates anything on the way. A plan that would is refused, and
  #     the operator lifts the protection in the provider's console, after which none is left.
  #
  # `{:ok, true}` when it applied a lift, which a later failure then names.
  # sobelow_skip ["Traversal.FileModule"]
  defp lift_protection(server) do
    instance = Provider.instance(server.provider)
    attribute = Provider.protection_attribute(server.provider)
    plan = Path.join(server.dir, "unprotect.tfplan")

    planning = [
      "plan",
      "-input=false",
      "-out=#{plan}",
      "-target=#{instance}" | var_file(server)
    ]

    if Provider.lifted_before_removal?(server.provider) do
      try do
        with :ok <- tofu(server, planning, :unprotected),
             {:ok, resources} <- resource_changes(server, plan) do
          case lift_planned(resources, instance, attribute) do
            :none ->
              {:ok, false}

            :lift ->
              server.progress.(
                {:step,
                 "Lifting #{Provider.title(server.provider)}'s deletion protection from " <>
                   "ehos-#{server.name}"}
              )

              with :ok <-
                     tofu(server, ["apply", "-input=false", "-auto-approve", plan], :unprotected),
                   do: {:ok, true}

            {:more, changed} ->
              {:error,
               "Lifting the deletion protection from ehos-#{server.name} would also change " <>
                 "#{Enum.join(changed, ", ")}. Nothing was changed. Turn off #{attribute} on " <>
                 "the instance ehos-#{server.name} in #{Provider.title(server.provider)}'s " <>
                 "console, then run this again"}
          end
        end
      after
        _removed = File.rm(plan)
      end
    else
      {:ok, false}
    end
  end

  # What a lift's plan does: nothing to lift, the lift alone, or more, named. The server's change is
  # its current object's: a deposed one, which this module never leaves, is not it. The lift alone
  # turns the attribute from true to false, and changes nothing else the plan knows, nor anything
  # it does not know yet, which OpenTofu leaves out of `after` and marks in `after_unknown`.
  defp lift_planned(resources, instance, attribute) do
    {changes, others} =
      Enum.split_with(resources, &(&1["address"] == instance and not Map.has_key?(&1, "deposed")))

    change = the_change(changes)

    more =
      for %{"address" => address, "change" => %{"actions" => actions}} <- others,
          actions not in [["no-op"], ["read"]],
          do: address

    lift? = lift_alone?(change, attribute)

    cond do
      dig(change, ["before", attribute]) != true -> :none
      lift? and more == [] -> :lift
      lift? -> {:more, more}
      true -> {:more, [instance | more]}
    end
  end

  defp the_change([%{"change" => change}]), do: change
  defp the_change(_none_or_many), do: %{}

  defp lift_alone?(change, attribute) do
    change["actions"] == ["update"] and dig(change, ["after", attribute]) == false and
      unchanged_but(change["before"], change["after"], attribute) and
      not unknown?(Map.delete(change["after_unknown"] || %{}, attribute))
  end

  # Whether every attribute the plan knows after it is the one before it, but `attribute`.
  defp unchanged_but(%{} = before, %{} = after_, attribute) do
    before
    |> Map.delete(attribute)
    |> Enum.all?(fn {key, value} -> not Map.has_key?(after_, key) or after_[key] == value end)
  end

  defp unchanged_but(_before, _after, _attribute), do: false

  # Whether `after_unknown` marks any value as not known until the apply.
  defp unknown?(true), do: true
  defp unknown?(%{} = map), do: map |> Map.values() |> Enum.any?(&unknown?/1)
  defp unknown?(list) when is_list(list), do: Enum.any?(list, &unknown?/1)
  defp unknown?(_known), do: false

  # A failure after the protection was lifted says so, and what to run next: `down` again to finish
  # removing the server, or `up` to keep it, which turns the protection back on.
  defp said_unprotected(result, server, lifted, next \\ :up)

  defp said_unprotected({:error, message}, server, true, next) do
    said =
      case next do
        :down ->
          "run #{suggested(server, "down")} again to finish removing it, or " <>
            "#{suggested(server, "up")} to keep it, which turns the protection back on"

        :up ->
          "#{suggested(server, "up")} turns it back on for a server still there"
      end

    {:error, message <> "\nThe deletion protection is lifted from ehos-#{server.name}; " <> said}
  end

  defp said_unprotected(result, _server, _lifted, _next), do: result

  defp resource_changes(server, plan) do
    case tofu_result(server, ["show", "-json", plan]) do
      {output, 0} ->
        case output |> json() |> Jason.decode() do
          {:ok, %{} = planned} -> {:ok, Map.get(planned, "resource_changes", [])}
          _other -> {:error, "`tofu show -json` did not print a plan"}
        end

      result ->
        failure("tofu", result)
    end
  end

  # The variables written, the module initialised, the plan made and read, and the place recorded:
  # what `changes/2` read of the plan, the addresses it removes, which `replace?` must allow,
  # among them.
  defp prepare_apply(server, vars, ssh_from, replace?, plan, next) do
    # `--replace` makes the server again even when nothing about it changed, which is how a
    # changed cloud-init document or a newer image reaches it.
    replacing =
      if replace?, do: ["-replace=#{Provider.instance(server.provider)}"], else: []

    planning = ["plan", "-input=false", "-out=#{plan}", "-var-file=#{next}" | replacing]

    with :ok <- write_vars(server, vars, next),
         :ok <- init(server),
         :ok <- making(server, ssh_from),
         :ok <- tofu(server, planning),
         {:ok, planned} <- planned(server, plan),
         :ok <- allow_removal(server, planned.deleted, replace?),
         :ok <- record_place(server, vars),
         :ok <- announce_resize(server, planned.resized) do
      {:ok, planned}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp keep_vars(server, next) do
    case File.rename(next, vars_path(server)) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "#{vars_path(server)} cannot be written: #{:file.format_error(reason)}"}
    end
  end

  defp removing(server) do
    server.progress.({:step, "Removing the server ehos-#{server.name} and its network"})
    :ok
  end

  defp making(server, ssh_from) do
    server.progress.(
      {:step,
       "Making the server ehos-#{server.name}, SSH admitted from #{Enum.join(ssh_from, ", ")}; " <>
         "this takes a few minutes"}
    )

    :ok
  end

  defp run_apply(server, plan, removed) do
    case tofu_result(server, ["apply", "-input=false", "-auto-approve", plan]) do
      # A server made again answers with another host key and another CA, perhaps at the same
      # address: what was recorded about the old one is forgotten once it is gone, and kept when
      # the apply failed and it is still there.
      # The account is pinned after every apply, a failed one included: one that failed partway
      # may have made billable resources already, and a profile that later names another account
      # must not make a second set there.
      {_output, 0} ->
        with :ok <- pin(server), do: forget_removed(server, removed)

      {output, status} when is_binary(output) ->
        unpinned =
          case pin(server) do
            :ok -> ""
            {:error, message} -> "\nThe account it was applied in is not recorded: " <> message
          end

        {:error,
         "`tofu apply` failed with exit status #{status}:\n" <>
           errors(output) <> Provider.capacity_hint(server.provider, output) <> unpinned}

      result ->
        failure("tofu", result)
    end
  end

  defp forget_removed(server, removed) do
    if Provider.instance(server.provider) in removed, do: forget(server), else: :ok
  end

  # Written once, before anything is made, so a failed apply that made part of the server still
  # names where it is; and only then, so a first `up` that failed earlier binds the name to
  # nothing. Only keeping the variables comes after it, a rename in the same directory, which
  # fails only when that directory is broken.
  defp record_place(%__MODULE__{place: nil} = server, vars),
    do: write_place(server, Provider.place(server.provider, vars))

  defp record_place(_server, _vars), do: :ok

  # The key whose `.pub` the variables about to be kept put on the server, so later commands log
  # in with it (ehos-tools#656). Recorded before they are kept, which stays the last step before
  # the apply. An Oracle installation made before D-83 has no `installation.json`: it gets one,
  # with the place its variables give, which every command reads as they did. Returns the key it
  # replaced in the record, if any.
  # sobelow_skip ["Traversal.FileModule"]
  defp record_key(server) do
    recorded = portable_path(server.ssh_key, server.user_home)

    with {:ok, %{} = place} <- recorded_place(server.dir),
         false <- place["ssh_key"] == recorded do
      with :ok <- write_place(server, Map.put(place, "ssh_key", recorded)),
           do: {:ok, place["ssh_key"] && Env.expand_home(place["ssh_key"], server.user_home)}
    else
      _recorded_or_no_place -> {:ok, nil}
    end
  end

  # An apply is not atomic: one that failed may or may not have put the new key on the server.
  # The record keeps the new key, as the variables the next `up` applies again do, and the error
  # names the key the server may still take.
  defp key_before({:error, message}, server, replaced) when is_binary(replaced),
    do:
      {:error,
       message <>
         "\nThe server may still take #{replaced}, the key `up` recorded before, until an `up` " <>
         "with #{server.ssh_key} succeeds: give `--ssh-key #{Shell.word(replaced)}` when this " <>
         "one is refused"}

  defp key_before(result, _server, _replaced), do: result

  # The key `up` recorded, which `key_kept/2` checked is a path.
  defp recorded_key(%{"ssh_key" => key}), do: key
  defp recorded_key(_place), do: nil

  @doc """
  `path` as `installation.json` records it: from `~/` when it is under `home`, so that a copy of
  the record names the key on another operator's machine too, and as given otherwise, as when
  `home` is `/` or `path` itself.

      iex> EhosPlatform.Server.portable_path("/home/ada/.ssh/ehos_acme", "/home/ada")
      "~/.ssh/ehos_acme"

      iex> EhosPlatform.Server.portable_path("/home/adam/.ssh/ehos_acme", "/home/ada")
      "/home/adam/.ssh/ehos_acme"
  """
  @spec portable_path(Path.t(), Path.t()) :: Path.t()
  def portable_path(path, "/"), do: path

  def portable_path(path, home) do
    case Path.relative_to(path, home) do
      relative when relative in [path, "."] -> path
      relative -> "~/" <> relative
    end
  end

  # After an apply, what the module says about where the server is that the variables could not:
  # on AWS the account's ID, which the provider is pinned to from then on (D-83).
  # sobelow_skip ["Traversal.FileModule"]
  defp pin(server) do
    with {output, key} <- Provider.pinned_output(server.provider),
         {:ok, contents} <- File.read(installation_path(server)),
         {:ok, %{} = place} <- Jason.decode(contents),
         false <- Map.has_key?(place, key),
         {:ok, value} <- output_value(server, output) do
      write_place(server, Map.put(place, key, value))
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _nothing_to_pin -> :ok
    end
  end

  defp output_value(server, name) do
    case tofu_result(server, ["output", "-json"]) do
      {output, 0} ->
        case output |> json() |> Jason.decode() do
          {:ok, %{^name => %{"value" => value}}} when is_binary(value) and value != "" ->
            {:ok, value}

          _other ->
            {:error,
             "The module did not say its #{name}; run #{suggested(server, "up")} again to " <>
               "record it"}
        end

      result ->
        failure("tofu", result)
    end
  end

  # Through a file beside it and a rename, so a write cut short leaves the old place, never half
  # of one.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_place(server, place) do
    path = installation_path(server)
    partial = path <> ".partial"

    with :ok <- File.write(partial, Jason.encode_to_iodata!(place)),
         :ok <- File.chmod(partial, 0o600),
         :ok <- File.rename(partial, path) do
      :ok
    else
      {:error, reason} -> {:error, "#{path} cannot be written: #{:file.format_error(reason)}"}
    end
  end

  # The addresses the plan deletes, a replacement's included, the server's size it changes in
  # place, each as "attribute before → after", and the server's public address in the plan's prior
  # state. OpenTofu writes an output's new value there when the plan knows it already, so it is the
  # old address only when the new one is not known until the apply, as when a reserved address is
  # made (eh-os D-124); a change the plan knows is not seen.
  defp planned(server, plan) do
    case tofu_result(server, ["show", "-json", plan]) do
      {output, 0} -> output |> json() |> Jason.decode() |> changes(server.provider)
      result -> failure("tofu", result)
    end
  end

  defp changes({:ok, %{} = plan}, provider) do
    resources =
      for %{"address" => address, "change" => %{"actions" => actions} = change} <-
            Map.get(plan, "resource_changes", []),
          do: {address, actions, change}

    instance = Provider.instance(provider)

    {:ok,
     %{
       deleted: for({address, actions, _change} <- resources, "delete" in actions, do: address),
       # Whether the apply changes anything, which makes the secrets of the server matter
       # again (ehos-tools T-30).
       changed?:
         Enum.any?(resources, fn {_address, actions, _change} ->
           actions not in [["no-op"], ["read"]]
         end),
       # A value the plan does not know yet, or one it does not hold, is nil, which each binding
       # below filters out.
       resized:
         for(
           {^instance, ["update"], change} <- resources,
           path <- Provider.size_attributes(provider),
           old = dig(change["before"], path),
           new = dig(change["after"], path),
           old != new,
           do: "#{List.last(path)} #{shown(old)} → #{shown(new)}"
         ),
       before:
         case dig(plan, ["prior_state", "values", "outputs", "public_ip", "value"]) do
           address when is_binary(address) -> address
           _none -> nil
         end
     }}
  end

  defp changes(_other, _provider), do: {:error, "`tofu show -json` did not print a plan"}

  defp shown(value) when is_binary(value) or is_number(value), do: to_string(value)
  defp shown(value), do: inspect(value)

  # A value among a resource's attributes, by a path of keys and list indices, or nil.
  defp dig(value, []), do: value
  defp dig(%{} = map, [key | path]) when is_binary(key), do: dig(Map.get(map, key), path)

  defp dig(list, [index | path]) when is_list(list) and is_integer(index),
    do: dig(Enum.at(list, index), path)

  defp dig(_value, _path), do: nil

  defp allow_removal(_server, [], _replace?), do: :ok
  defp allow_removal(_server, _removed, true), do: :ok

  defp allow_removal(server, removed, false) do
    {:error,
     "Applying this would remove or replace #{Enum.join(removed, ", ")}, and everything on " <>
       "ehos-#{server.name} with it. Nothing was changed. If that is meant, run " <>
       "#{suggested(server, "up")} again with --replace; a different --availability-domain " <>
       "than before is a different server"}
  end

  # The state's address is what the last apply saw. One interrupted while the server was being
  # made can keep the address the server had then, which the provider may since have given to
  # someone else's machine, so the state is refreshed from the provider first.
  defp refreshed_address(server) do
    with :ok <- scope_held(server),
         :ok <-
           tofu(server, [
             "apply",
             "-refresh-only",
             # The instance and what it depends on, not the rest: its address is all this needs.
             "-target=#{Provider.instance(server.provider)}",
             "-input=false",
             "-auto-approve" | var_file(server)
           ]),
         do: address(server)
  end

  # eh-os D-127: on OVHcloud the credentials are a clouds.yaml entry, whose project the provider
  # takes whatever the module says, and a destroy or a targeted refresh reads no data source. One
  # whose credentials scope another project would find nothing of the installation there, empty the
  # state and report success, the server running on unseen. So before either, a plan, which
  # changes and keeps nothing, reads the scope, and the module's postcondition refuses any project
  # but the recorded one. A plain plan: in a refresh-only one, OpenTofu reports a failed condition
  # as a warning and succeeds.
  defp scope_held(%__MODULE__{provider: :ovh} = server) do
    case tofu_result(server, ["plan", "-input=false" | var_file(server)]) do
      {_output, 0} ->
        :ok

      {output, _status} when is_binary(output) ->
        # The entry is the recorded variables', which only `up` rewrites: `--os-cloud` on this
        # command would not reach the plan.
        {:error,
         "OpenTofu's plan before this command failed, so nothing was changed. If it says the " <>
           "credentials scope another project than the one ehos-#{server.name} was made in, " <>
           "name the clouds.yaml entry for that project with " <>
           suggested(server, "up --os-cloud ENTRY") <>
           ", which records it, then run this " <>
           "command again:\n" <> errors(output)}

      result ->
        failure("tofu", result)
    end
  end

  defp scope_held(_server), do: :ok

  defp address(server) do
    case tofu_result(server, ["output", "-json"]) do
      {output, 0} ->
        case output |> json() |> Jason.decode() do
          {:ok, %{"public_ip" => %{"value" => address}}} when is_binary(address) -> {:ok, address}
          _other -> {:error, "The state has no server. Make it with #{suggested(server, "up")}"}
        end

      {output, status} when is_binary(output) ->
        {:error, "`tofu output` failed with exit status #{status}:\n" <> errors(output)}

      result ->
        failure("tofu", result)
    end
  end

  # How many times `up` tries to reach the server over SSH after the apply, and how long apart.
  @first_boot_attempts 30
  @first_boot_interval 10_000

  # cloud-init's `status --wait` returns once the first boot is done: 0 when every step passed.
  # SSH refuses until the server's sshd starts, which is retried; 255 is ssh's own failure.
  # `waited` is when the wait began and how many whole minutes of it were said, or `nil` before
  # the first try that SSH refused.
  defp wait_for_first_boot(server, address, attempts \\ @first_boot_attempts, waited \\ nil) do
    case ssh(server, address, ["cloud-init status --wait >/dev/null; cloud-init status --long"]) do
      {output, 0} ->
        if output =~ "status: done",
          do: :ok,
          else: {:error, "The server's first boot did not finish cleanly:\n" <> output}

      # cloud-init 23.4 and later exit 2 when the boot finished with recoverable errors, such as a
      # deprecated key; what k3s needs ran.
      {output, 2} ->
        if output =~ "status: done" do
          server.progress.(
            {:warning, "The first boot of ehos-#{server.name} finished with recoverable errors.",
             nil}
          )

          server.progress.({:tool_output, "cloud-init status --long", output})
          :ok
        else
          {:error, "The server's first boot did not finish cleanly:\n" <> output}
        end

      {output, 255} when is_binary(output) ->
        not_answering(server, address, attempts, output, waited)

      {output, status} when is_binary(output) ->
        {:error,
         "The server's first boot failed (exit status #{status}). Its log is " <>
           "/var/log/cloud-init-output.log on the server:\n" <> output}

      result ->
        failure("ssh", result)
    end
  end

  defp not_answering(server, address, attempts, output, waited) do
    cond do
      # A host key known for this address, and another one answering: never retried (D-124).
      output =~ "Host key verification failed" ->
        {:error,
         "The server at #{address} answered SSH with another host key than the one " <>
           "recorded for ehos-#{server.name}. The module was applied, but nothing was run " <>
           "on the server. Compare the keys with #{Provider.console(server.provider)} " <>
           "before trusting it:\n" <> output}

      attempts > 1 ->
        waited = say_waiting(server, waited)
        server.clock.sleep(@first_boot_interval)
        wait_for_first_boot(server, address, attempts - 1, waited)

      true ->
        {:error,
         "The server at #{address} never answered SSH:\n" <> output <> boot_hint(server, output)}
    end
  end

  # A sign of life while SSH does not answer: when the wait begins, and then once for each whole
  # minute of it, by the clock, so that a try which takes its own time counts too.
  defp say_waiting(server, nil) do
    text = String.trim("Waiting for the server to answer SSH. " <> admitted(server))
    server.progress.({:waiting, text, 0})
    %{text: text, began: server.clock.utc_now(), minutes: 0}
  end

  defp say_waiting(server, waited) do
    elapsed = DateTime.diff(server.clock.utc_now(), waited.began, :millisecond)
    minutes = div(elapsed, 60_000)

    if minutes > waited.minutes do
      server.progress.({:waiting, waited.text, elapsed})
      %{waited | minutes: minutes}
    else
      waited
    end
  end

  # The tunnel is kept when it already goes where it should; one to another address or port, or
  # a control socket left by a master that is gone, is cleared first, since `ssh -M` beside a
  # stale socket would open a forward nothing can close.
  # sobelow_skip ["Traversal.FileModule"]
  defp open(server, address, port) do
    target = %{"address" => address, "port" => port}

    case control(server, address, "check") do
      :ok ->
        if tunnel_target(server) == target, do: :ok, else: reopen(server, target)

      :not_open ->
        start_tunnel(server, target)

      # A master that does not answer may still hold the port: clearing its socket would leave a
      # forward nothing can close, so the operator stops it (eh-os#291).
      :timeout ->
        {:error, wedged(server)}
    end
  end

  defp reopen(server, target) do
    case close(server) do
      :timeout -> {:error, wedged(server)}
      _closed -> start_tunnel(server, target)
    end
  end

  # `pkill -f` matches the pattern anywhere in a command line, so it is the arguments only the
  # master is started with, `master_args/1`, as `start_tunnel/2` gives them: not the
  # `ssh -S <socket> -O check` that may hang beside it, nor anything else that names the path
  # (ehos-tools#571). `--` keeps a pattern that starts with `-` from reading as pkill's option.
  defp wedged(server) do
    socket = socket_path(server)
    master = server |> master_args() |> Enum.map_join(" ", &Shell.pattern/1)

    "The tunnel's ssh master does not answer on #{socket} within #{div(@control_timeout, 1000)} " <>
      "seconds. Stop it (`pkill -f -- #{Shell.word(master)}`), then run this again"
  end

  # What makes an ssh the tunnel's master, one after another on its command line.
  defp master_args(server),
    do: ["-M", "-S", socket_path(server), "-o", "ExitOnForwardFailure=yes"]

  # sobelow_skip ["Traversal.FileModule"]
  defp start_tunnel(server, %{"address" => address, "port" => port} = target) do
    server.progress.({:step, "Opening the tunnel to #{address}"})
    # `-O exit` returns before the old master unlinks its socket; `ssh -M` beside a socket that
    # exists opens a forward without one, which nothing could close.
    _removed = File.rm(socket_path(server))

    args =
      ssh_options(server) ++
        [
          "-f",
          "-N"
        ] ++
        master_args(server) ++
        [
          "-L",
          "127.0.0.1:#{port}:127.0.0.1:6443",
          "#{@user}@#{address}"
        ]

    # `ssh -f` goes to the background once the forward is up, keeping the output it was given; a
    # pipe would then never close and the call would never return. So its output goes to a file
    # in the installation, read back when it fails.
    log = Path.join(server.dir, "tunnel.log")
    script = ~S(exec ssh "$@" </dev/null >"$0" 2>&1)

    case server.runner.run("sh", ["-c", script, log | args]) do
      {_output, 0} ->
        case File.write(tunnel_path(server), Jason.encode!(target)) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error,
             "The tunnel is open, but #{tunnel_path(server)} cannot be written: " <>
               "#{:file.format_error(reason)}. Close it with #{suggested(server, "tunnel --close")}"}
        end

      {_output, status} when is_integer(status) ->
        output = read_log(log)

        {:error,
         "`ssh` could not open the tunnel (exit status #{status}):\n" <>
           output <> ssh_hint(server, output)}

      result ->
        failure("sh", result)
    end
  end

  # The port this installation's open tunnel holds, or the first from 16443 that no other
  # installation's open tunnel holds: two installations' tunnels on one port would fail, the second
  # with `ExitOnForwardFailure` (eh-os#253). Another installation's record counts only while its
  # control socket answers: a master that died without `tunnel --close`, in a reboot or a sleep,
  # leaves its record behind and holds nothing (eh-os#285). So does this installation's own: a port
  # it held before a reboot may be another's open tunnel's now.
  # sobelow_skip ["Traversal.FileModule"]
  defp default_port(server) do
    case tunnel_target(server) do
      %{"port" => port} when port in 1..65_535//1 ->
        if open?(server, socket_path(server)), do: port, else: free_port(server)

      _none ->
        free_port(server)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp free_port(server) do
    home = Path.dirname(server.dir)

    # Installations only: a name `up` takes holds no `%` or `~`, which ssh would expand in `-S`.
    others =
      case File.ls(home) do
        {:ok, names} -> Enum.filter(names -- [server.name], &valid_name?/1)
        {:error, _reason} -> []
      end

    taken =
      for name <- others,
          dir = Path.join(home, name),
          %{"port" => port} <- [read_tunnel(Path.join(dir, "tunnel.json"))],
          open?(server, Path.join(dir, "tunnel.sock")),
          into: MapSet.new(),
          do: port

    Enum.find(@default_port..65_535//1, @default_port, &(&1 not in taken))
  end

  # Whether an ssh master answers on `socket`; none is asked where there is no socket. The host is
  # a placeholder, as for `-O exit`: the socket names the master, and nothing read from another
  # installation's record reaches ssh's command line.
  # sobelow_skip ["Traversal.FileModule"]
  # One that does not answer in time counts as open: its port is not taken for another tunnel.
  defp open?(server, socket),
    do:
      File.exists?(socket) and
        control_socket(server, socket, "server", "check") in [:ok, :timeout]

  defp tunnel_target(server), do: read_tunnel(tunnel_path(server))

  @doc """
  The record of a tunnel at `path`, `tunnel.json`, as a map, or `nil` when it is missing, is not a
  small regular file, or is not a JSON object.
  """
  @spec read_tunnel(Path.t()) :: map() | nil

  @record_limit 4096

  # A tunnel's record: a small regular file, never a FIFO or a link to a device, which would
  # block or never end. `lstat` refuses those before the file is opened, since opening a FIFO
  # blocks; the open file is then checked again, by its handle, to be the regular file `lstat`
  # saw, and read at most to the limit, so a file swapped in between is neither read without end
  # nor taken for the record. Erlang opens neither without blocking on a FIFO nor without
  # following a link (no `O_NONBLOCK` or `O_NOFOLLOW`), so a FIFO swapped in between the two can
  # still block the open itself; the directory is the operator's own, mode 0700 (eh-os#285).
  # sobelow_skip ["Traversal.FileModule"]
  def read_tunnel(path) do
    with {:ok, %File.Stat{type: :regular, size: size} = seen} when size <= @record_limit <-
           File.lstat(path),
         {:ok, contents} <- read_record(path, seen),
         {:ok, %{} = target} <- Jason.decode(contents) do
      target
    else
      _none -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_record(path, seen) do
    with {:ok, file} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(file, time: :posix),
             %File.Stat{type: :regular, inode: inode, major_device: device}
             when inode == seen.inode and device == seen.major_device <-
               File.Stat.from_record(info),
             {:ok, contents} when byte_size(contents) <= @record_limit <-
               :file.read(file, @record_limit + 1) do
          {:ok, contents}
        else
          _other -> :error
        end
      after
        :file.close(file)
      end
    end
  end

  # eh-os D-124: a server whose address changed, as one made with an ephemeral address does once
  # when it moves to a reserved one. What outside the installation admitted the old address, and
  # the console's host that names it, must be told.
  # Said as soon as the apply is done, before the server is reached: a run that fails after it
  # still says it, and the next run sees no change of address to say again.
  defp moved(server, before, address) when is_binary(before) and before != address do
    server.progress.(
      {:warning, "The address of ehos-#{server.name} changed from #{before} to #{address}.",
       moved_note(server, address)}
    )

    :ok
  end

  defp moved(_server, _before, _address), do: :ok

  defp moved_note(server, address),
    do:
      "#{Provider.title(server.provider)} can give the old address to someone else. Remove " <>
        "the old address now from each rule that admits it, such as a mail relay's rule. Stop " <>
        "the pipelines that still name it. Give the new address to each rule and pipeline " <>
        "that needs it.\n" <>
        "A console's host of sslip.io names the old address too: install EHOS again with " <>
        "--host #{EhosPlatform.Install.sslip_host(address)}, which every application's address " <>
        "follows. A host of your own needs its DNS record changed instead."

  # D-124: a server moved to another address in place is the same server, with the same host key.
  # Its keys are recorded for the new address too before it is reached, so `accept-new` refuses a
  # different key there, as it would at the old one. A server made again was forgotten already.
  # sobelow_skip ["Traversal.FileModule"]
  defp carry_host_key(server, before, address) when is_binary(before) and before != address do
    path = Path.join(server.dir, "known_hosts")

    case File.read(path) do
      {:ok, contents} -> carry_host_key_in(path, contents, before, address)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "#{path} cannot be read: #{:file.format_error(reason)}"}
    end
  end

  defp carry_host_key(_server, _before, _address), do: :ok

  defp carry_host_key_in(path, contents, before, address) do
    lines = String.split(contents, "\n", trim: true)
    known? = Enum.any?(lines, &(&1 |> host_field() |> Enum.member?(address)))

    carried =
      for line <- lines,
          before in host_field(line),
          [_hosts, rest] <- [String.split(line, " ", parts: 2)],
          do: address <> " " <> rest

    # A file whose last line has no newline, as one edited by hand may, is given one first.
    separator = if contents == "" or String.ends_with?(contents, "\n"), do: "", else: "\n"

    if known? or carried == [],
      do: :ok,
      else: append_host_keys(path, separator <> Enum.map_join(carried, &(&1 <> "\n")))
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp append_host_keys(path, keys) do
    case File.write(path, keys, [:append]) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{path} cannot be written: #{:file.format_error(reason)}"}
    end
  end

  defp host_field(line), do: line |> String.split(" ", parts: 2) |> hd() |> String.split(",")

  # The host key was trusted on first contact. Its fingerprint, as `ssh-keygen -l` prints it, can
  # be compared with the ones cloud-init writes to the instance's console output, which no one
  # between this machine and the server can change.
  defp host_key_values(server, address) do
    case host_key_fingerprints(Path.join(server.dir, "known_hosts"), address) do
      [] ->
        []

      fingerprints ->
        [
          {"SSH host key",
           Enum.join(fingerprints, "\n") <>
             "\nTrusted on first contact. Compare it with #{Provider.console(server.provider)}."}
        ]
    end
  end

  @doc """
  The SHA-256 fingerprints of `address`'s keys in a `known_hosts` file, as `ssh-keygen -l` prints
  them, or none when the file is missing or names other hosts only.
  """
  @spec host_key_fingerprints(Path.t(), String.t()) :: [String.t()]
  # sobelow_skip ["Traversal.FileModule"]
  def host_key_fingerprints(path, address) do
    case File.read(path) do
      {:ok, contents} ->
        for line <- String.split(contents, "\n", trim: true),
            [hosts, type, key | _] <- [String.split(line, " ")],
            address in String.split(hosts, ","),
            {:ok, blob} <- [Base.decode64(key)] do
          "#{type} SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)
        end

      {:error, _reason} ->
        []
    end
  end

  # A server that refused the key answered: the address is admitted, and the key is the cause
  # (ehos-tools#656).
  defp ssh_hint(server, output) do
    if output =~ "Permission denied (publickey",
      do: key_hint(server),
      else: address_hint(server)
  end

  # In `up`, the key refused is the one it just put on the server: giving it again changes nothing.
  defp boot_hint(server, output) do
    if output =~ "Permission denied (publickey",
      do:
        "\nThe server refused the key #{server.ssh_key} that `up` put on it. " <>
          not_written(
            server.provider,
            "what the first boot said in " <> Provider.console(server.provider)
          ),
      else: address_hint(server)
  end

  # GCP refuses the keys in an instance's metadata when OS Login is enforced, as an organisation
  # policy can do.
  defp not_written(:gcp, log),
    do:
      "An organisation policy that enforces OS Login refuses every key that `up` puts on a " <>
        "server; else cloud-init did not write it. Read #{log}"

  defp not_written(_provider, log), do: "Cloud-init may not have written it: read #{log}"

  # A recorded key this machine lacks, as from a copy of the installation, is not refused: it was
  # never offered.
  # sobelow_skip ["Traversal.FileModule"]
  defp key_hint(server) do
    if server.key_recorded and not File.regular?(server.ssh_key),
      do: "\nThe key #{server.ssh_key} that `up` recorded is not on this machine. " <> give_key(),
      else: refused_hint(server)
  end

  defp refused_hint(server) do
    differs = if other_key?(server), do: ": #{other_key()}", else: ""
    "\nThe server refused the SSH key #{server.ssh_key}#{differs}. " <> give_key()
  end

  defp give_key, do: "Give the private key that `up` put on the server with `--ssh-key`"
  defp other_key, do: "its .pub is not the public key that `up` put on the server"

  # Said before a command connects, since the server answers such a key only with a refusal. Not
  # refused: a key can also be on the server that `up` did not put there.
  defp warn_other_key(server) do
    if other_key?(server) do
      server.progress.(
        {:warning,
         "#{server.ssh_key}.pub is not the public key that `up` put on ehos-#{server.name}.",
         "The server can refuse it. " <> give_key() <> "."}
      )
    end

    :ok
  end

  # Whether the key's `.pub` is another key than the one the last `up` wrote into the variables,
  # by type and key, whatever their comments; false when either is not known.
  # sobelow_skip ["Traversal.FileModule"]
  defp other_key?(server) do
    with %{"ssh_public_key" => recorded} when is_binary(recorded) <- recorded_vars(server),
         {:ok, public} <- File.read(server.ssh_key <> ".pub") do
      key_words(public) != key_words(recorded)
    else
      _unknown -> false
    end
  end

  defp key_words(public_key), do: public_key |> String.split() |> Enum.take(2)

  # SSH is admitted from the addresses `up` wrote, by default the one this machine had then. A
  # connection that changes its public address, as many home and mobile ones do, is then dropped
  # by the cloud's firewall without an answer.
  # ehos-tools#157: the addresses admitted are said, since a machine whose network leaves through
  # another one waits for SSH with nothing else to tell it why.
  defp address_hint(server) do
    "\n" <>
      admitted(server) <>
      "If this machine's public address changed since the server was last brought up, run " <>
      "#{suggested(server, "up")} again: it " <>
      "admits the current ones in place of those admitted before. A network can also reach the " <>
      "internet through more than one address, and SSH may leave through one that was not seen: " <>
      "give `--ssh-from` each of them, as `<address>/32`, or the range your provider assigns from, /16 or narrower"
  end

  defp admitted(server) do
    case previous(server, "ssh_from", []) do
      [_ | _] = blocks -> "SSH is admitted from #{Enum.join(blocks, ", ")} only. "
      _none -> ""
    end
  end

  # The runner gives a program's errors with its output, and OpenTofu warns on stderr. `-json`
  # prints one object, which starts a line with `{` and ends a line with `}`: the first such
  # stretch that decodes is it, so a warning beside it, braces and all, is left out. When none
  # decodes, the caller refuses rather than guesses.
  defp json(output) do
    lines = output |> String.split("\n") |> Enum.drop_while(&(not String.starts_with?(&1, "{")))

    1..max(length(lines), 1)//1
    |> Stream.map(&(lines |> Enum.take(&1) |> Enum.join("\n")))
    |> Enum.find(output, &match?({:ok, %{}}, Jason.decode(&1)))
  end

  # OpenTofu prints the whole plan before an error; the error and what follows it is what says
  # what went wrong.
  defp errors(output) do
    case :binary.match(output, "Error:") do
      {start, _length} -> binary_part(output, start, byte_size(output) - start)
      :nomatch -> output
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_log(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp close(server) do
    closed = File.exists?(socket_path(server)) and control(server, "server", "exit")

    # A master that does not answer may still hold the port its record names: the record stays,
    # so no other tunnel takes that port meanwhile.
    case closed do
      :ok ->
        _removed = File.rm(tunnel_path(server))
        :ok

      :timeout ->
        :timeout

      _not_open ->
        _removed = File.rm(tunnel_path(server))
        :not_open
    end
  end

  # What the installation knows about a server that is going: the tunnel to it, its host key and
  # its kubeconfig.
  defp forget(server) do
    _closed = close(server)
    forget_files(server)
  end

  # D-124: the address the server had before an apply, kept until the server is reached at the one
  # it has after. A run that stops in between, once the state holds the new address, would leave
  # the next run's plan no change to see: it reads this instead, so the note and the host key's
  # carry are not lost. An older one is never overwritten by a later run's.
  @previous_address "previous_address"

  # sobelow_skip ["Traversal.FileModule"]
  defp forget_files(server),
    do:
      Enum.each(
        ["known_hosts", "kubeconfig", @previous_address],
        &File.rm(Path.join(server.dir, &1))
      )

  # sobelow_skip ["Traversal.FileModule"]
  defp previous_address(server) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= 64 <-
           File.lstat(Path.join(server.dir, @previous_address)),
         {:ok, contents} <- File.read(Path.join(server.dir, @previous_address)),
         address = String.trim(contents),
         {:ok, _ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)) do
      address
    else
      _none -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp keep_previous_address(server, address) when is_binary(address) do
    case File.write(Path.join(server.dir, @previous_address), address <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "#{@previous_address} cannot be written: #{:file.format_error(reason)}"}
    end
  end

  defp keep_previous_address(_server, _address), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp forget_previous_address(server), do: File.rm(Path.join(server.dir, @previous_address))

  defp control(server, address, command),
    do: control_socket(server, socket_path(server), address, command)

  # eh-os#291: a master that is wedged, or a socket that accepts and never answers, would block `-O`
  # for ever, and `ConnectTimeout` does not cover the multiplexing handshake: the command is
  # bounded. `-F none`, since the socket names the master and the operator's `~/.ssh/config`, a
  # `Match exec` in it for one, has nothing to add to a control command.
  defp control_socket(server, socket, address, command) do
    args = ["-F", "none", "-S", socket, "-O", command, "#{@user}@#{address}"]

    case server.runner.run_bounded("ssh", args, @control_timeout) do
      {_output, 0} -> :ok
      {:error, :timeout} -> :timeout
      _not_open -> :not_open
    end
  end

  # The kubeconfig k3s writes holds the cluster's CA and an admin client key. It is read over SSH
  # and written readable by this user alone; it is never printed, so a failure says what went
  # wrong without its contents. `{:ok, new?}`: whether its credential differs from the one in the
  # file before, which another server, not another port, gives (ehos-tools T-30).
  # sobelow_skip ["Traversal.FileModule"]
  defp write_kubeconfig(server, address, port) do
    before = kubeconfig_path(server) |> File.read() |> credential_hash()

    with {:ok, contents} <- read_remote_kubeconfig(server, address),
         {:ok, config} <- rewrite_kubeconfig(contents, context(server), port),
         :ok <- File.write(kubeconfig_path(server), Jason.encode_to_iodata!(config, pretty: true)),
         :ok <- File.chmod(kubeconfig_path(server), 0o600) do
      {:ok, before == nil or before != credential_hash({:ok, config})}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "#{kubeconfig_path(server)} cannot be written: #{:file.format_error(reason)}"}

      error ->
        error
    end
  end

  defp read_remote_kubeconfig(server, address) do
    case ssh(server, address, ["sudo cat /etc/rancher/k3s/k3s.yaml 2>/dev/null"]) do
      {contents, 0} ->
        {:ok, contents}

      {_contents, status} when is_integer(status) ->
        {:error, "The server's kubeconfig could not be read over SSH (exit status #{status})"}

      result ->
        failure("ssh", result)
    end
  end

  @doc """
  Turns the kubeconfig k3s writes, whose cluster, user and context are all `default` and whose
  server is `https://127.0.0.1:6443`, into one whose names are `context` and whose server is the
  tunnel's local `port`. k3s's certificate names 127.0.0.1, so TLS is verified as it is on the
  server.
  """
  @spec rewrite_kubeconfig(String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, String.t()}
  def rewrite_kubeconfig(contents, context, port) do
    with {:ok, %{"clusters" => [cluster], "users" => [user]} = config} <-
           YamlElixir.read_from_string(contents),
         %{"cluster" => %{} = cluster_data} <- cluster,
         %{"user" => %{} = user_data} <- user do
      {:ok,
       %{
         config
         | "clusters" => [
             %{
               "name" => context,
               "cluster" => Map.put(cluster_data, "server", "https://127.0.0.1:#{port}")
             }
           ],
           "users" => [%{"name" => context, "user" => user_data}]
       }
       |> Map.put("contexts", [
         %{"name" => context, "context" => %{"cluster" => context, "user" => context}}
       ])
       |> Map.put("current-context", context)}
    else
      _other ->
        {:error, "The server's kubeconfig is not one cluster and one user, as k3s writes it"}
    end
  end

  defp ssh(server, address, command) do
    server.runner.run("ssh", ssh_options(server) ++ ["#{@user}@#{address}" | command])
  end

  # The host key is recorded on first contact in the installation's own known_hosts, which `down`
  # removes, so a server made again is met as new and a different key at a known address is
  # refused.
  defp ssh_options(server) do
    [
      "-i",
      server.ssh_key,
      "-o",
      "IdentitiesOnly=yes",
      "-o",
      "UserKnownHostsFile=#{Path.join(server.dir, "known_hosts")}",
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=10",
      # A session that goes silent, as when this machine's address changes during
      # `cloud-init status --wait`, ends after a minute instead of never.
      "-o",
      "ServerAliveInterval=15",
      "-o",
      "ServerAliveCountMax=4",
      "-o",
      "LogLevel=ERROR",
      # Plain host names, so the fingerprint `up` prints can be found; Debian and Ubuntu hash them
      # by default.
      "-o",
      "HashKnownHosts=no"
    ]
  end

  # `protection` is `:unprotected` for the commands that lift the provider's deletion protection
  # and remove the server; every other runs with the module's own, whatever the operator's shell
  # sets.
  defp tofu(server, args, protection \\ :protected) do
    case tofu_result(server, args, protection) do
      {_output, 0} -> :ok
      result -> failure("tofu", result)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp tofu_result(server, args, protection \\ :protected) do
    result = run_tofu(server, args, protection)
    # OpenTofu writes the state, and its backup, readable by others; the directory is not, and the
    # state is encrypted, but the files are kept as private as everything else here.
    Enum.each(Path.wildcard(Path.join(server.dir, "terraform.tfstate*")), &File.chmod(&1, 0o600))
    result
  end

  defp run_tofu(server, args, protection) do
    env = [
      {"TF_VAR_state_passphrase", server.passphrase},
      {"TF_VAR_deletion_protection", if(protection == :unprotected, do: "false")},
      {"TF_DATA_DIR", Path.join(server.dir, "tofu")},
      {"TF_PLUGIN_CACHE_DIR", plugin_cache(server)},
      {"TF_IN_AUTOMATION", "1"}
      | cli_args() ++ server.provider_env
    ]

    case server.source do
      %Source{} = source ->
        module = Source.module(source, Provider.name(server.provider))
        server.runner.run_env("tofu", ["-chdir=#{module}" | args] ++ ["-no-color"], env)

      nil ->
        raise ArgumentError, @no_source
    end
  end

  # Arguments an operator's shell would add to every OpenTofu command, a `-var` among them, which
  # would beat the installation's variables file.
  defp cli_args do
    for command <- ["", "_init", "_plan", "_apply", "_destroy", "_output", "_show"],
        do: {"TF_CLI_ARGS" <> command, nil}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp plugin_cache(server), do: Path.join(Path.dirname(server.dir), "plugin-cache")

  defp var_file(server), do: ["-var-file=#{vars_path(server)}"]
  defp vars_path(server), do: Path.join(server.dir, "server.tfvars.json")
  defp installation_path(server), do: Path.join(server.dir, "installation.json")
  defp kubeconfig_path(server), do: Path.join(server.dir, "kubeconfig")

  # A hash of the client certificate and key of a kubeconfig this module wrote, as JSON, or as
  # the map it decodes to, computed in memory and never kept; nil when there is none.
  defp credential_hash({:ok, contents}) when is_binary(contents),
    do: contents |> Jason.decode() |> credential_hash()

  defp credential_hash({:ok, %{"users" => [%{"user" => %{} = user} | _]}}) do
    with cert when is_binary(cert) <- user["client-certificate-data"],
         key when is_binary(key) <- user["client-key-data"] do
      :crypto.hash(:sha256, [cert, 0, key])
    else
      _missing -> nil
    end
  end

  defp credential_hash(_none), do: nil
  defp tunnel_path(server), do: Path.join(server.dir, "tunnel.json")
  defp socket_path(server), do: Path.join(server.dir, "tunnel.sock")
  defp context(server), do: "ehos-#{server.name}"

  defp failure(program, {:error, :not_found}),
    do:
      {:error,
       "`#{program}` is not installed, or not at the version EHOS pins: `ehosctl doctor` says what is missing (`mix ehos.doctor` in eh-os)"}

  defp failure(program, {output, status}),
    do: {:error, "`#{program}` failed with exit status #{status}:\n" <> output}
end
