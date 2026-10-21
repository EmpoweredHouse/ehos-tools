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

  The SMTP server EHOS sends mail through (eh-os D-36), so the console's invitations arrive by
  email, is given by `--smtp-host`, `--smtp-port`, `--smtp-username` and `--mail-from`, and its
  password by `SMTP_PASSWORD` alone, never an option; both are kept from the running EHOS, as the
  sign-in limits are, until `--no-mail` stops it (ehos-tools#298).

  Whether a promotion to production needs a second person (eh-os D-105) is `--four-eyes` or
  `--no-four-eyes`, kept from the running EHOS when neither is given, as the sign-in limits are:
  no later install or upgrade of EHOS 0.9.0 or later changes it (ehos-tools#296). When neither the
  flags nor the running EHOS say, the chart decides: a new installation of EHOS 0.14.0 or later
  runs without four eyes, one before 0.14.0 with them, and from 0.14.0 an upgrade or a reinstall
  keeps what the installation had, with four eyes on where the chart cannot tell (eh-os D-128). An
  EHOS before 0.9.0 has no promotions to approve, so a move to one drops the setting, and past it
  four eyes are on again, until EHOS 0.14.0 or later reads back what it recorded before.
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
          "with your kubeconfig and GHCR_TOKEN, and SMTP_PASSWORD for an SMTP server's user.",
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
        ] ++ sign_in_options() ++ mail_options(),
      flags: four_eyes_flags() ++ mail_flags()
    ]
  end

  @doc """
  The options that name the SMTP server EHOS sends mail through (eh-os D-36), `install`'s and
  `upgrade`'s.
  """
  @spec mail_options() :: keyword()
  def mail_options do
    [
      smtp_host: [
        long: "--smtp-host",
        value_name: "HOST",
        help:
          "The SMTP server EHOS sends mail through, so invitations arrive by email; the one EHOS " <>
            "runs with, else none. TLS is always on and verified."
      ],
      smtp_port: [
        long: "--smtp-port",
        value_name: "PORT",
        help: "Its port: 587 for STARTTLS (the default), 465 for TLS from the first byte."
      ],
      smtp_username: [
        long: "--smtp-username",
        value_name: "USER",
        help:
          "The user to authenticate as, whose password is SMTP_PASSWORD, or the one the cluster " <>
            "holds; \"\" for none."
      ],
      mail_from: [
        long: "--mail-from",
        value_name: "ADDRESS",
        help: "The address EHOS sends mail from; needed with an SMTP server."
      ]
    ]
  end

  @doc "The flags that say whether a promotion needs a second person (eh-os D-105)."
  @spec four_eyes_flags() :: keyword()
  def four_eyes_flags do
    [
      four_eyes: [
        long: "--four-eyes",
        help:
          "Turn four eyes on: a promotion to production needs a second person, neither who " <>
            "deployed the candidate nor who asked. A new EHOS 0.14.0 or later runs without them."
      ],
      no_four_eyes: [
        long: "--no-four-eyes",
        help:
          "Let who deployed or asked approve their own promotion, each recorded as a " <>
            "self-approval: for an installation of one person. Kept by later upgrades."
      ]
    ]
  end

  # eh-os D-105: the first EHOS whose chart takes `governance.promotion.fourEyes`.
  @four_eyes_since "0.9.0"
  # eh-os D-128: the first whose chart keeps what the installation runs when no value is given.
  @four_eyes_kept_since "0.14.0"

  @doc """
  Whether the chart of EHOS `version` keeps the four eyes an installation runs when it is given no
  value (eh-os D-128), rather than turning them on.
  """
  @spec four_eyes_kept?(String.t()) :: boolean()
  def four_eyes_kept?(version), do: since?(version, @four_eyes_kept_since)

  @doc """
  Whether a promotion to production needs a second person on `version` (eh-os D-105): what
  `--four-eyes` or `--no-four-eyes` in `parsed` says, else what the running EHOS was installed
  with, `running`; `nil` when neither says, which leaves it to the chart: on before EHOS 0.14.0,
  eh-os D-128 from it. An EHOS before #{@four_eyes_since} has no such setting: a flag given is
  refused, and a kept value is not sent.
  """
  @spec four_eyes(Optimus.ParseResult.t(), boolean() | nil, String.t()) ::
          {:ok, boolean() | nil} | {:error, :invalid, String.t()}
  def four_eyes(parsed, running, version) do
    given = given_four_eyes(parsed)

    cond do
      parsed.flags[:four_eyes] && parsed.flags[:no_four_eyes] ->
        {:error, :invalid, "Give --four-eyes or --no-four-eyes, not both."}

      since?(version, @four_eyes_since) ->
        {:ok, if(given == nil, do: running, else: given)}

      given != nil ->
        {:error, :invalid,
         "EHOS #{version} has no setting for four eyes: promotions arrive in " <>
           "#{@four_eyes_since}. Leave out #{four_eyes_argument(given)}, or name " <>
           "#{@four_eyes_since} or later."}

      true ->
        {:ok, nil}
    end
  end

  @doc "What `--four-eyes` or `--no-four-eyes` in `parsed` says; `nil` for neither."
  @spec given_four_eyes(Optimus.ParseResult.t()) :: boolean() | nil
  def given_four_eyes(parsed) do
    cond do
      parsed.flags[:no_four_eyes] -> false
      parsed.flags[:four_eyes] -> true
      true -> nil
    end
  end

  @doc "The flag that says `four_eyes`, as a command line names it; none for `nil`."
  @spec four_eyes_argument(boolean() | nil) :: String.t()
  def four_eyes_argument(true), do: "--four-eyes"
  def four_eyes_argument(false), do: "--no-four-eyes"
  def four_eyes_argument(nil), do: ""

  @doc "The flag that stops EHOS sending mail, `install`'s and `upgrade`'s."
  @spec mail_flags() :: keyword()
  def mail_flags do
    [
      no_mail: [
        long: "--no-mail",
        help:
          "Send no mail: forget the SMTP server EHOS runs with. Its password stays in the cluster."
      ]
    ]
  end

  @doc """
  The SMTP server to install with (eh-os D-36), as `EhosPlatform.Install.server/1`'s `:mail`
  takes it: what `parsed` gives over what the running EHOS was installed with, `running`; `nil`
  for none, as `--no-mail` asks. A host needs a sender and the other way round, the port is
  1–65535 (587 unless given), and each value is one the chart and a mail header take; refused
  before anything changes.
  """
  @spec mail(Optimus.ParseResult.t(), Platform.mail() | :unreadable | nil) ::
          {:ok, Platform.mail() | nil} | {:error, :invalid, String.t()}
  def mail(parsed, running) do
    given = given_mail(parsed)
    replaced? = Map.has_key?(given, "host") and Map.has_key?(given, "from")

    cond do
      parsed.flags[:no_mail] && given != %{} ->
        {:error, :invalid,
         "--no-mail stops EHOS sending mail: leave out #{given_options(given)} with it."}

      parsed.flags[:no_mail] ->
        {:ok, nil}

      running == :unreadable and not replaced? ->
        {:error, :invalid,
         "EHOS here sends mail through settings ehosctl did not write (governance.mail in its " <>
           "Helm release): give --smtp-host and --mail-from to replace them, or --no-mail. " <>
           "Nothing was changed."}

      true ->
        running = if is_map(running), do: running, else: %{}
        smtp = Map.get(running, "smtp", %{})

        merged = %{
          "host" => Map.get(given, "host", smtp["host"]),
          "port" => Map.get(given, "port", smtp["port"]),
          "username" => Map.get(given, "username", smtp["username"]),
          "from" => Map.get(given, "from", running["from"])
        }

        mail_of(merged, given)
    end
  end

  defp mail_of(%{"host" => nil, "from" => nil}, given) when given == %{}, do: {:ok, nil}

  defp mail_of(%{"host" => nil}, given),
    do:
      {:error, :invalid,
       "#{given_options(given)} #{if map_size(given) == 1, do: "needs", else: "need"} " <>
         "--smtp-host, the SMTP server EHOS sends mail through."}

  defp mail_of(%{"from" => nil}, _given),
    do: {:error, :invalid, "--smtp-host needs --mail-from, the address EHOS sends mail from."}

  defp mail_of(%{"host" => host, "port" => port, "username" => username, "from" => from}, given) do
    with :ok <- check(Platform.mail_host?(host), given, "host", host, "a DNS name"),
         {:ok, port} <- port(port),
         :ok <- check(Platform.mail_address?(from), given, "from", from, "an email address"),
         :ok <-
           check(
             username in [nil, ""] or Platform.mail_username?(username),
             given,
             "username",
             username,
             "printable ASCII, without spaces"
           ) do
      smtp = %{"host" => host, "port" => port}
      smtp = if username in [nil, ""], do: smtp, else: Map.put(smtp, "username", username)
      {:ok, %{"from" => from, "smtp" => smtp}}
    end
  end

  defp port(nil), do: {:ok, 587}
  defp port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}

  defp port(port) when is_binary(port) do
    case Integer.parse(port) do
      {number, ""} when number in 1..65_535 -> {:ok, number}
      _other -> {:error, :invalid, "--smtp-port must be a port, 1 to 65535, not #{inspect(port)}"}
    end
  end

  # Only a given value can fail: what EHOS runs with was read through the same checks.
  defp check(true, _given, _key, _value, _rule), do: :ok

  defp check(false, _given, key, value, rule),
    do: {:error, :invalid, "#{option(key)} must be #{rule}, not #{Refusal.shown(inspect(value))}"}

  @doc """
  `:ok` unless the SMTP server `mail` authenticates as a user the password the cluster holds was
  not given for: another host or user than the running EHOS's `running`, or none running. Then
  `SMTP_PASSWORD` must give it, or EHOS would send the old server's password to the new one. A
  `SMTP_PASSWORD` with no server to give it to is refused too, unless `--no-mail` (`no_mail?`)
  says the mail is stopped, rather than dropped without a word.
  """
  @spec password_given(
          Platform.mail() | nil,
          Platform.mail() | :unreadable | nil,
          map(),
          boolean()
        ) ::
          :ok | {:error, :invalid, String.t()}
  def password_given(mail, running, env, no_mail?) do
    user = mail && get_in(mail, ["smtp", "username"])
    password = env["SMTP_PASSWORD"]

    cond do
      mail == nil and password not in [nil, ""] and not no_mail? ->
        {:error, :invalid,
         "SMTP_PASSWORD is set, but no SMTP server is: give --smtp-host and --mail-from, unset " <>
           "SMTP_PASSWORD, or say --no-mail. Nothing was changed."}

      user in [nil, ""] or password not in [nil, ""] ->
        :ok

      # DNS names are compared without case.
      is_map(running) and
        String.downcase(running["smtp"]["host"]) == String.downcase(mail["smtp"]["host"]) and
          running["smtp"]["username"] == user ->
        :ok

      true ->
        {:error, :invalid,
         "SMTP_PASSWORD must give the password of #{user} at #{mail["smtp"]["host"]}: the one " <>
           "the cluster holds, if any, was given for #{held_for(running)}. Nothing was changed."}
    end
  end

  defp held_for(%{"smtp" => %{"host" => host, "username" => user}}), do: "#{user} at #{host}"
  defp held_for(:unreadable), do: "settings ehosctl did not write"
  defp held_for(_running), do: "no user EHOS runs with"

  @doc "The SMTP options `parsed` gives, by the key `mail/2` merges them under."
  @spec given_mail(Optimus.ParseResult.t()) :: %{optional(String.t()) => String.t()}
  def given_mail(parsed) do
    for {key, option} <- [
          {"host", :smtp_host},
          {"port", :smtp_port},
          {"username", :smtp_username},
          {"from", :mail_from}
        ],
        value = parsed.options[option],
        into: %{},
        do: {key, value}
  end

  @doc "The SMTP options `given_mail/1` gave, as a command line names them."
  @spec mail_arguments(%{optional(String.t()) => String.t()}) :: String.t()
  def mail_arguments(given) do
    given
    |> Enum.sort()
    |> Enum.map_join(fn {key, value} -> " #{option(key)} #{shell_word(value)}" end)
  end

  defp given_options(given),
    do: given |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &option/1)

  defp option("host"), do: "--smtp-host"
  defp option("port"), do: "--smtp-port"
  defp option("username"), do: "--smtp-username"
  defp option("from"), do: "--mail-from"

  defp shell_word(""), do: ~s("")

  # Quoted for a POSIX shell, a single quote within as '\''.
  defp shell_word(value) do
    if value =~ ~r/\A[A-Za-z0-9@%+=:,.\/_-]+\z/,
      do: value,
      else: "'" <> String.replace(value, "'", ~S('\'')) <> "'"
  end

  @doc false
  def env(opts), do: Keyword.get_lazy(opts, :env, &System.get_env/0)

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
           "#{@sign_in_since}. Leave out --sign-in-absolute and --sign-in-idle, or name " <>
           "#{@sign_in_since} or later as the release to install."}

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

  defp sign_in_setting?(version), do: since?(version, @sign_in_since)

  defp since?(version, since) do
    case Version.parse(version) do
      {:ok, parsed} -> Version.compare(parsed, Version.parse!(since)) != :lt
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
         :ok <- host_kept(parsed.options[:host], installed.host, name, opts, &"give #{&1}"),
         {:ok, sign_in} <- sign_in(parsed, installed.sign_in, wanted["version"]),
         {:ok, four_eyes} <- four_eyes(parsed, installed.four_eyes, wanted["version"]),
         {:ok, mail} <- mail(parsed, installed.mail),
         :ok <- password_given(mail, installed.mail, env(opts), parsed.flags[:no_mail] == true),
         {:ok, done} <-
           install(
             name,
             wanted,
             parsed.options[:host] || installed.host,
             opts
             |> Keyword.put(:sign_in, sign_in)
             |> Keyword.put(:four_eyes, four_eyes)
             |> Keyword.put(:mail, mail)
           ) do
      {:ok, %{done | text: failed_before(installed) <> done.text}}
    end
  end

  @doc """
  `:ok` unless the console's host the running EHOS serves, kept when `given` is `nil`, is
  sslip.io's name for another address than the one the installation's tunnel goes to: the
  server's address changed, as a server on Oracle's does once when it moves to a reserved address
  (eh-os D-124), and the kept host would name the old one. `remedy` turns the `--host` that would
  fix it into what the person is told to do.
  """
  @spec host_kept(String.t() | nil, String.t() | nil, String.t(), keyword(), (String.t() ->
                                                                                String.t())) ::
          :ok | {:error, :invalid, String.t()}
  def host_kept(given, host, name, opts, remedy) do
    old = EhosPlatform.Install.sslip_address(host)

    new =
      EhosPlatform.Install.tunnel_address(name: name, home: Keyword.get(opts, :home, "~/.ehos"))

    if given == nil and old != nil and new != nil and old != new do
      {:error, :invalid,
       "EHOS on #{name} serves its console at #{host}, which names #{old}, but the server is at " <>
         "#{new} now (eh-os D-124). To move the console, and every application's address with " <>
         "it, #{remedy.("--host #{EhosPlatform.Install.sslip_host(new)}")}. Nothing was changed."}
    else
      :ok
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
  `:sign_in`, the sign-in limits `sign_in/3` gave (eh-os D-113), or none for the chart's,
  `:four_eyes`, what `four_eyes/3` gave (eh-os D-105), or none for the chart's, and `:mail`, the
  SMTP server `mail/2` gave (eh-os D-36), or none to send no mail.
  """
  @spec install(String.t(), %{String.t() => String.t()}, String.t() | nil, keyword()) ::
          Ehosctl.Command.result()
  def install(name, wanted, host, opts) do
    install = Keyword.get(opts, :install, Platform)
    env = env(opts)

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
                   four_eyes: Keyword.get(opts, :four_eyes),
                   mail: Keyword.get(opts, :mail),
                   # A password left in the shell is not sent where --no-mail stops the mail.
                   smtp_password: if(Keyword.get(opts, :mail), do: env["SMTP_PASSWORD"]),
                   token: env["GHCR_TOKEN"],
                   username: env["GHCR_USERNAME"],
                   # eh-os#823: a server running k3s's Traefik is switched over SSH first.
                   passphrase: env["EHOS_STATE_PASSPHRASE"],
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
