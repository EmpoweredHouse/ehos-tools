defmodule Ehosctl.Install do
  @moduledoc """
  `ehosctl install`: installs EHOS, by version, on the server under an installation (eh-os D-79,
  D-92), with `EhosPlatform.Install` run through `Ehosctl.PlatformRunner` at the tool versions EHOS
  is tested with (T-13), through the kubeconfig `ehosctl server tunnel` wrote.

  The version is a release's, the newest unless `--version` names another, and its `release.json`
  names the image and the chart, each by digest (`Ehosctl.EhosRelease`): nobody copies a digest.
  What it installs is recorded in the Helm release, and read back before anything is changed:

    * nothing installed: EHOS is installed;
    * the same version, image and chart: it is installed again, which changes nothing in place;
    * another version, or an EHOS whose version cannot be read, as `mix ehos.install` leaves it:
      refused, since moving it is `ehosctl upgrade`'s (`Ehosctl.Upgrade`);
    * the same version with other digests: refused, since its release was changed.

  What runs is the Helm release's last deployed revision. A later one still pending is an
  operation running, or one that was interrupted, and nothing is changed under it; a later one
  that failed is said. The console's host is the one the running EHOS serves, unless `--host`
  names another, so installing the same version again keeps its address.

  The registry credential is `GHCR_TOKEN`, a classic token with `read:packages` alone: the cluster
  keeps it for the image after the first install, and Helm pulls the chart with it while EHOS's
  packages are private. Once EHOS runs, the installation is put in `config.json`
  under its name, with the console's address and the installation's CA, so `ehosctl login
  --installation <name>` needs no `EHOSCTL_CA_FILE` (T-13, T-14). `upgrade` installs through
  `install/4` too.
  """

  @behaviour Ehosctl.Command

  alias EhosPlatform.Install, as: Platform
  alias EhosPlatform.Source
  alias Ehosctl.Config
  alias Ehosctl.EhosRelease
  alias Ehosctl.Refusal

  @impl Ehosctl.Command
  def name, do: :install

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Install EHOS, by version, on the server under an installation, through its tunnel, " <>
          "with your kubeconfig and GHCR_TOKEN.",
      options:
        [
          installation: [
            long: "--installation",
            value_name: "NAME",
            help:
              "The installation whose server this is, instead of EHOSCTL_INSTALLATION, the " <>
                "current one, or trial."
          ],
          version: [
            long: "--version",
            value_name: "V",
            help: "The EHOS release to install; the newest by default."
          ],
          host: [
            long: "--host",
            value_name: "HOST",
            help:
              "The console's host, instead of the one EHOS serves there, or ehos.<address>.sslip.io " <>
                "from the tunnel's address on a first install."
          ]
        ] ++ sign_in_options()
    ]
  end

  @doc """
  The options that set how long a sign-in to an application lasts (eh-os D-113), `install`'s and
  `upgrade`'s.
  """
  @spec sign_in_options() :: keyword()
  def sign_in_options do
    [
      sign_in_absolute: [
        long: "--sign-in-absolute",
        value_name: "DURATION",
        help:
          "How long a person's sign-in to an application lasts from signing in at EHOS, in hours " <>
            "or days (12h, 30d), at most 366d; the one EHOS runs with, else 12h."
      ],
      sign_in_idle: [
        long: "--sign-in-idle",
        value_name: "DURATION",
        help:
          "How long such a sign-in lasts unused, in hours or days, at most the absolute one; the " <>
            "one EHOS runs with, else 1h."
      ]
    ]
  end

  # eh-os D-113: the first EHOS whose chart takes `governance.signIn`. An earlier one ignores it and
  # keeps 12 hours and 1 hour.
  @sign_in_since "0.10.0"

  @doc """
  The sign-in limits to install `version` with (eh-os D-113): those `parsed` gives, over those the
  running EHOS was installed with, `running`. Each is whole hours or days, `idle` at most
  `absolute` and `absolute` at most 366 days, where one left out is the chart's default (12h, 1h);
  refused before anything changes, as the chart would refuse it halfway. `nil` when neither gives
  any. An EHOS before #{@sign_in_since} has no such setting: given ones are refused, and kept ones
  are not sent, since it would ignore them.
  """
  @spec sign_in(Optimus.ParseResult.t(), map() | nil, String.t()) ::
          {:ok, %{optional(String.t()) => String.t()} | nil} | {:error, :invalid, String.t()}
  def sign_in(parsed, running, version) do
    given = given_sign_in(parsed)
    limits = Map.merge(running || %{}, given)

    cond do
      sign_in_setting?(version) ->
        with :ok <- each_limit(given),
             :ok <- within(limits, given) do
          {:ok, if(limits == %{}, do: nil, else: limits)}
        end

      given != %{} ->
        {:error, :invalid,
         "EHOS #{version} has no sign-in limits to set: they are 12h and 1h until " <>
           "#{@sign_in_since}. Leave out --sign-in-absolute and --sign-in-idle, or install " <>
           "#{@sign_in_since} or later."}

      true ->
        {:ok, nil}
    end
  end

  @doc "The `--sign-in-*` options `parsed` gives, by the chart's key."
  @spec given_sign_in(Optimus.ParseResult.t()) :: %{optional(String.t()) => String.t()}
  def given_sign_in(parsed) do
    for {key, option} <- [{"absolute", :sign_in_absolute}, {"idle", :sign_in_idle}],
        value = parsed.options[option],
        into: %{},
        do: {key, value}
  end

  defp sign_in_setting?(version) do
    case Version.parse(version) do
      {:ok, parsed} -> Version.compare(parsed, Version.parse!(@sign_in_since)) != :lt
      :error -> false
    end
  end

  defp each_limit(given) do
    case Enum.reject(given, fn {_key, value} -> Platform.sign_in_limit?(value) end) do
      [] ->
        :ok

      [{key, value} | _rest] ->
        {:error, :invalid,
         "--sign-in-#{key} must be whole hours or days, such as 12h or 30d, not #{inspect(value)}"}
    end
  end

  # As the chart holds them (eh-os D-113), with its defaults for a value left out. A value not
  # given is named as the running EHOS's or the default, so no message blames an option left out.
  defp within(limits, given) do
    absolute = Map.get(limits, "absolute", "12h")
    idle = Map.get(limits, "idle", "1h")

    cond do
      seconds(absolute) > 366 * 86_400 ->
        {:error, :invalid, "#{named("absolute", absolute, given, limits)} must be at most 366d"}

      seconds(idle) > seconds(absolute) ->
        {:error, :invalid,
         "#{named("idle", idle, given, limits)} must be at most " <>
           named("absolute", absolute, given, limits)}

      true ->
        :ok
    end
  end

  defp named(key, value, given, limits) do
    cond do
      Map.has_key?(given, key) -> "--sign-in-#{key} (#{value})"
      Map.has_key?(limits, key) -> "the #{key} limit EHOS runs with (#{value})"
      true -> "the default #{key} limit (#{value})"
    end
  end

  defp seconds(value) do
    {number, unit} = Integer.parse(value)
    number * if(unit == "d", do: 86_400, else: 3_600)
  end

  @doc """
  Installs. `opts` may name, for tests, `:install` (the module that does the work,
  `EhosPlatform.Install` by default), `:home` (`~/.ehos`), `:env`, `:config_dir`, `:progress`,
  `:runner`, and `Ehosctl.GitHub`'s options.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    with {:ok, name} <- Ehosctl.Server.installation(parsed.options[:installation], opts),
         {:ok, installed} <- installed(name, opts),
         :ok <- settled(installed, name, opts),
         {:ok, release, described} <- EhosRelease.find(parsed.options[:version], opts),
         {:ok, wanted} <- EhosRelease.installable(release, described),
         :ok <- may_install(installed.running, wanted, name),
         {:ok, sign_in} <- sign_in(parsed, installed.sign_in, wanted["version"]),
         {:ok, done} <-
           install(
             name,
             wanted,
             parsed.options[:host] || installed.host,
             Keyword.put(opts, :sign_in, sign_in)
           ) do
      {:ok, %{done | text: failed_before(installed) <> done.text}}
    end
  end

  @doc """
  What runs on the installation `name`'s server (`t:EhosPlatform.Install.installed/0`), read
  through its kubeconfig. `opts` as `call/3`'s.
  """
  @spec installed(String.t(), keyword()) ::
          {:ok, Platform.installed()} | {:error, Ehosctl.Output.kind(), String.t()}
  def installed(name, opts) do
    install = Keyword.get(opts, :install, Platform)
    platform(install.installed(base(name, opts)))
  end

  @doc """
  `:ok` unless the release's last revision is one Helm is still on: `pending-install`,
  `pending-upgrade`, `pending-rollback`, `uninstalling` or `unknown`. An operation on it is
  running, or one was interrupted, and nothing is changed under it. A last revision that failed is
  said by `failed_before/1`, and one that was uninstalled is installed over, as Helm does; the work
  goes on from what runs. `opts` as `call/3`'s.
  """
  @spec settled(Platform.installed(), String.t(), keyword()) ::
          :ok | {:error, :failed, String.t()}
  def settled(%{last: %{status: status} = last} = installed, name, opts)
      when status not in ["failed", "uninstalled", "superseded", "deployed"] do
    kubeconfig =
      opts |> Keyword.get(:home, "~/.ehos") |> Path.join(name) |> Path.join("kubeconfig")

    helm = "helm --kubeconfig #{kubeconfig} --kube-context ehos-#{name} -n ehos-system"

    # Interrupted with nothing deployed before it, as a first install can be, it is removed;
    # over a deployed revision, it is rolled back to that one.
    way_out =
      if installed.running == :none,
        do: "`#{helm} uninstall ehos` removes it, since nothing ran before it",
        else: "`#{helm} rollback ehos <the last deployed revision>` ends it"

    {:error, :failed,
     "The last change to EHOS on #{name}, Helm's revision #{last.revision}, is " <>
       "#{Refusal.shown(status)} (#{Refusal.shown(last.description)}): an install or upgrade " <>
       "is running, or one was interrupted. Wait for it to end; if it was interrupted, " <>
       "`#{helm} history ehos` shows the revisions, and #{way_out}, before running this " <>
       "again. Nothing was changed."}
  end

  def settled(_installed, _name, _opts), do: :ok

  @doc "A line that says the release's last revision failed, or nothing."
  @spec failed_before(Platform.installed()) :: String.t()
  def failed_before(%{last: %{status: "failed"} = last}),
    do:
      "The last attempt, Helm's revision #{last.revision}, had failed " <>
        "(#{Refusal.shown(last.description)}).\n"

  def failed_before(_installed), do: ""

  @doc """
  Installs `wanted`, a release as `Ehosctl.EhosRelease.installable/2` gives it, on the
  installation `name`'s server, on the console's host `host` (`nil`: the one the tunnel's address
  gives), then keeps the installation in `config.json` for `login`. `opts` as `call/3`'s, and
  `:sign_in`, the sign-in limits `sign_in/2` gave (eh-os D-113), or none for the chart's.
  """
  @spec install(String.t(), %{String.t() => String.t()}, String.t() | nil, keyword()) ::
          Ehosctl.Command.result()
  def install(name, wanted, host, opts) do
    install = Keyword.get(opts, :install, Platform)
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    with {:ok, message} <-
           platform(
             install.server(
               base(name, opts) ++
                 [
                   source: %Source{chart: {:oci, wanted["chart"]}, modules: nil},
                   digest: wanted["digest"],
                   installed: Map.take(wanted, ["version", "image", "chart"]),
                   host: host,
                   sign_in: Keyword.get(opts, :sign_in),
                   token: env["GHCR_TOKEN"],
                   username: env["GHCR_USERNAME"],
                   progress: Keyword.get(opts, :progress, &progress/1)
                 ]
             )
           ) do
      home = Keyword.get(opts, :home, "~/.ehos")
      {:ok, %{text: message <> "\n" <> signed_in(name, home, opts), json: nil}}
    end
  end

  defp base(name, opts),
    do: [
      name: name,
      home: Keyword.get(opts, :home, "~/.ehos"),
      runner: Keyword.get(opts, :runner, Ehosctl.PlatformRunner),
      server_command: "ehosctl server",
      name_option: "--installation",
      name_in_commands: true
    ]

  defp may_install(:none, _wanted, _name), do: :ok

  defp may_install(%{"version" => v} = running, %{"version" => v} = wanted, name) do
    if running["image"] == wanted["image"] and running["chart"] == wanted["chart"],
      do: :ok,
      else:
        {:error, :failed,
         "#{name} runs EHOS #{Refusal.shown(v)} as #{Refusal.shown(running["image"])}, from " <>
           "#{Refusal.shown(running["chart"])}, but its release now names #{wanted["image"]}, " <>
           "from #{wanted["chart"]}. A release is not changed once published: find out who " <>
           "changed it before installing anything from it. Nothing was changed."}
  end

  defp may_install(%{"version" => running}, %{"version" => wanted}, name),
    do:
      {:error, :invalid,
       "#{name} runs EHOS #{Refusal.shown(running)}; moving it to #{Refusal.shown(wanted)} is " <>
         "not an install: `ehosctl upgrade --installation #{name} --to #{wanted}` does it. " <>
         "Nothing was changed."}

  defp may_install(:unknown, _wanted, name),
    do:
      {:error, :invalid,
       "#{name} runs an EHOS whose version ehosctl cannot read from the cluster, as " <>
         "`mix ehos.install` leaves it: `ehosctl upgrade --installation #{name}` moves it to a " <>
         "release. Nothing was changed."}

  # The installation in `config.json`, for `login` (T-13, T-14): what `EhosPlatform.Install`
  # wrote beside the installation says its host and its CA. A failure here leaves EHOS running,
  # and says how to sign in without it.
  defp signed_in(name, home, opts) do
    dir = home |> Path.expand() |> Path.join(name)
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env) end)
    ca_file = Path.join(dir, "ca.crt")

    host = installed_host(dir)
    url = if host, do: "https://#{host}", else: "https://<the console's host>"

    with true <- host != nil,
         {:ok, pem} when is_binary(pem) <-
           Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => ca_file}),
         {:ok, config} <- Config.read(config_dir),
         before = config.installations[name],
         config = config |> Config.put(name, url) |> Config.put_ca(name, pem),
         :ok <- Config.write(config, config_dir) do
      replaced(before, name, url) <>
        "Sign in with `ehosctl login --installation #{name}`: it trusts the installation's CA."
    else
      _not_kept ->
        "Sign in with `EHOSCTL_CA_FILE=#{ca_file} ehosctl login --installation #{name} " <>
          "#{url}`: ehosctl could not keep the installation in its configuration."
    end
  end

  # An installation of that name elsewhere is now this one, which the person should know: their
  # commands to it go here from now on.
  defp replaced(%{"url" => old}, name, url) when old != url,
    do: "The installation #{name} was at #{Ehosctl.Refusal.shown(old)}; it is #{url} now.\n"

  defp replaced(_before, _name, _url), do: ""

  defp installed_host(dir) do
    with {:ok, contents} <- File.read(Path.join(dir, "install.json")),
         {:ok, %{"host" => host}} when is_binary(host) <- JSON.decode(contents),
         true <- Ehosctl.Output.printable?(host) do
      host
    else
      _unread -> nil
    end
  end

  defp platform({:ok, result}), do: {:ok, result}
  defp platform({:error, message}), do: {:error, :failed, message}

  # A line may hold what the server printed, as cloud-init's errors (#165).
  defp progress(line), do: IO.puts(:stderr, "==> " <> Ehosctl.Output.shown_lines(line))
end
