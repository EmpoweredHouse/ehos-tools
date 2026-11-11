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

  The company's domains under which a person can map a domain to an application (eh-os D-155)
  are `--allowed-domain`, given once for each, which replaces the list, or
  `--no-allowed-domains`, which empties it. With neither, the list of the running EHOS is kept, as
  the sign-in limits are, and `upgrade` keeps it too: Helm does not reuse a release's values, so a
  list not given again would be emptied. `EhosPlatform.Install` refuses a domain on the Public
  Suffix List, the console's host, and allowed domains without public certificates.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Config
  alias Ehosctl.EhosRelease
  alias Ehosctl.Refusal
  alias EhosPlatform.Install, as: Platform
  alias EhosPlatform.Source

  @impl Ehosctl.Command
  def name, do: :install

  @impl Ehosctl.Command
  def plane, do: :platform

  @impl Ehosctl.Command
  def spec do
    [
      about:
        "Install a release of EHOS on the server of an installation, through the tunnel to the " <>
          "server. Needs GHCR_TOKEN, and SMTP_PASSWORD for a user of an SMTP server.",
      options:
        [
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
            help: "The release of EHOS to install. By default the newest release."
          ],
          host: [
            long: "--host",
            value_name: "HOST",
            help:
              "The host of the console. By default the host that EHOS serves now, or " <>
                "ehos.<address>.sslip.io on a first install, from the address of the tunnel."
          ]
        ] ++
          sign_in_options() ++ mail_options() ++ switch_options() ++ allowed_domains_options(),
      flags:
        four_eyes_flags() ++
          mail_flags() ++
          switch_flags() ++ public_certificates_flags() ++ allowed_domains_flags()
    ]
  end

  @doc """
  The option that names the company's domains under which a person can map a domain to an
  application (eh-os D-155), `install`'s and `upgrade`'s.
  """
  @spec allowed_domains_options() :: keyword()
  def allowed_domains_options do
    [
      allowed_domain: [
        long: "--allowed-domain",
        value_name: "DOMAIN",
        multiple: true,
        help:
          "A domain of your company, such as client.example. A person can then map it, or a " <>
            "name under it, to an application in production. Give it once for each domain; " <>
            "the list replaces the list that EHOS has. By default EHOS keeps its list. Needs " <>
            "public certificates. Format: lowercase, as an A-label, never on the Public Suffix " <>
            "List."
      ]
    ]
  end

  @doc "The flag that empties the allowed domains (eh-os D-155), `install`'s and `upgrade`'s."
  @spec allowed_domains_flags() :: keyword()
  def allowed_domains_flags do
    [
      no_allowed_domains: [
        long: "--no-allowed-domains",
        help:
          "Remove all allowed domains. Remove each mapped domain first: EHOS refuses a route " <>
            "for a domain that is not allowed."
      ]
    ]
  end

  # eh-os D-155: the first EHOS whose chart takes `environments.domains.allowed`.
  @allowed_domains_since "0.27.0"

  @doc """
  The domains to allow on `version` (eh-os D-155): those `--allowed-domain` in `parsed` gives,
  without duplicates, `[]` for `--no-allowed-domains`, else those the running EHOS allows,
  `running`. `nil` when none of them says, which leaves the chart's empty list. An EHOS before
  #{@allowed_domains_since} has no such setting: given ones are refused, and kept ones are not
  sent.
  """
  @spec allowed_domains(Optimus.ParseResult.t(), [String.t()] | nil, String.t()) ::
          {:ok, [String.t()] | nil} | {:error, :invalid, String.t()}
  def allowed_domains(parsed, running, version) do
    given = parsed.options[:allowed_domain] || []
    none? = parsed.flags[:no_allowed_domains] == true

    cond do
      none? and given != [] ->
        {:error, :invalid,
         "--no-allowed-domains removes all allowed domains, so it takes no --allowed-domain. " <>
           "Give one of them."}

      since?(version, @allowed_domains_since) ->
        {:ok, chosen_domains(given, none?, running)}

      given != [] or none? ->
        {:error, :invalid,
         "EHOS #{version} has no allowed domains: domains of your company start in " <>
           "#{@allowed_domains_since}. Leave out --allowed-domain and --no-allowed-domains, or " <>
           "install #{@allowed_domains_since} or later."}

      true ->
        {:ok, nil}
    end
  end

  defp chosen_domains([], true, _running), do: []
  defp chosen_domains([], false, running), do: running
  defp chosen_domains(given, false, _running), do: Enum.uniq(given)

  @doc """
  The option and flag that switch a server running k3s's Traefik to EHOS's (eh-os D-117,
  eh-os#823), `install`'s and `upgrade`'s: the switch reaches the server over SSH, with the key it
  was made with, and takes the console down for a few minutes, so it is done only when asked.
  """
  @spec switch_options() :: keyword()
  def switch_options do
    [
      ssh_key: [
        long: "--ssh-key",
        value_name: "PATH",
        help:
          "The private key that made the server, for --switch-traefik. By default the key that " <>
            "`ehosctl server up` recorded, else ~/.ssh/ehos_oci."
      ]
    ]
  end

  @doc "See `switch_options/0`."
  @spec switch_flags() :: keyword()
  def switch_flags do
    [
      switch_traefik: [
        long: "--switch-traefik",
        help:
          "Replace the Traefik of k3s with the Traefik of EHOS, on a server made before EHOS " <>
            "0.15.0. k3s restarts, and the console and its applications stop for a few minutes. " <>
            "Without this flag, ehosctl refuses such a server. Needs EHOS_STATE_PASSPHRASE."
      ]
    ]
  end

  @doc """
  `install`'s own flags for certificates from Let's Encrypt (eh-os D-158): `--public-certificates`,
  which an installation that has them keeps on every later install and upgrade, and
  `--skip-port-53-check` (ehos-tools#891).
  """
  @spec public_certificates_flags() :: keyword()
  def public_certificates_flags do
    [
      public_certificates: [
        long: "--public-certificates",
        help:
          "Get the certificates of the console and the applications from Let's Encrypt. Needs " <>
            "--host with a host of your company's own, and a server made with `ehosctl server " <>
            "up --public-certificates`. The first run prints the DNS records to make; run it " <>
            "again once they are made. If EHOS runs under the installation's own CA, the " <>
            "second run moves it to the host, and each person must sign in again."
      ],
      skip_port_53_check: [
        long: "--skip-port-53-check",
        help:
          "With --public-certificates, go on with a warning when acme-dns on the server does " <>
            "not answer on port 53 from this machine. For a network that answers DNS itself, " <>
            "for any address. Use it only when you know that port 53 of the server is open."
      ]
    ]
  end

  @doc "What `switch_options/0` and `switch_flags/0` gave, as `install/4` takes them."
  @spec switch(Optimus.ParseResult.t()) :: keyword()
  def switch(parsed),
    do: [switch_traefik: parsed.flags[:switch_traefik] == true, ssh_key: parsed.options[:ssh_key]]

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
          "The SMTP server that EHOS sends mail through, such as invitations. By default the " <>
            "server that EHOS uses now, else none. TLS is always on and verified."
      ],
      smtp_port: [
        long: "--smtp-port",
        value_name: "PORT",
        help:
          "The port of the SMTP server: 587 for STARTTLS (the default), or 465 for TLS from the " <>
            "first byte."
      ],
      smtp_username: [
        long: "--smtp-username",
        value_name: "USER",
        help:
          "The user that EHOS signs in to the SMTP server as, with SMTP_PASSWORD. By default the " <>
            "user that EHOS uses now. Give \"\" for none."
      ],
      mail_from: [
        long: "--mail-from",
        value_name: "ADDRESS",
        help: "The address that EHOS sends mail from. EHOS needs it with an SMTP server."
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
          "Turn on four eyes: a second person approves each promotion to production, not the " <>
            "person who deployed the candidate or asked. A new EHOS 0.14.0 or later starts " <>
            "without four eyes."
      ],
      no_four_eyes: [
        long: "--no-four-eyes",
        help:
          "Let the person who deployed or asked approve their own promotion. EHOS records it as " <>
            "a self-approval. For an installation of one person. Later upgrades keep it."
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
         "EHOS #{version} has no setting for four eyes, because promotions start in " <>
           "#{@four_eyes_since}. Leave out #{four_eyes_argument(given)}, or install " <>
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
          "Stop the mail of EHOS: EHOS forgets its SMTP server. The password stays in the cluster."
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
         "--no-mail stops the mail of EHOS, so it takes no SMTP option. Leave out " <>
           "#{given_options(given)}."}

      parsed.flags[:no_mail] ->
        {:ok, nil}

      running == :unreadable and not replaced? ->
        {:error, :invalid,
         "EHOS sends mail through settings that ehosctl did not write (governance.mail in its " <>
           "Helm release). Give --smtp-host and --mail-from to replace them, or give --no-mail. " <>
           "ehosctl changed nothing."}

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
         "--smtp-host, the SMTP server that EHOS sends mail through."}

  defp mail_of(%{"from" => nil}, _given),
    do:
      {:error, :invalid, "--smtp-host needs --mail-from, the address that EHOS sends mail from."}

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
      {number, ""} when number in 1..65_535 ->
        {:ok, number}

      _other ->
        {:error, :invalid,
         "--smtp-port must be a port from 1 to 65535, and #{inspect(port)} is not. Give a " <>
           "port in that range."}
    end
  end

  # Only a given value can fail: what EHOS runs with was read through the same checks.
  defp check(true, _given, _key, _value, _rule), do: :ok

  defp check(false, _given, key, value, rule),
    do:
      {:error, :invalid,
       "#{option(key)} must be #{rule}, and #{Refusal.shown(inspect(value))} is not. Give " <>
         "#{rule}."}

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
         "SMTP_PASSWORD is set, but EHOS has no SMTP server to use it with. Give --smtp-host " <>
           "and --mail-from, unset SMTP_PASSWORD, or give --no-mail. ehosctl changed nothing."}

      user in [nil, ""] or password not in [nil, ""] ->
        :ok

      held?(running, mail, user) ->
        :ok

      true ->
        {:error, :invalid,
         "The cluster holds no password for #{user} at #{mail["smtp"]["host"]}: its password, " <>
           "if any, is for #{held_for(running)}. Set SMTP_PASSWORD to the password of " <>
           "#{user}, and run the command again. ehosctl changed nothing."}
    end
  end

  @doc """
  Warns on stderr when EHOS is to send mail through an SMTP server `mail` with
  no user (eh-os D-141): a relay that admits the server by its address admits every application on
  it, which may reach the relay's host under `needs.egress` and send around its mail agreement.
  Said, not refused, as a server with too little CPU is (eh-os D-138): EHOS cannot know how the
  relay admits, and the installation administrator chooses. Always `:ok`.
  """
  @spec warn_relay(Platform.mail() | nil) :: :ok
  def warn_relay(%{"smtp" => %{"host" => host, "port" => port} = smtp})
      when not is_map_key(smtp, "username") do
    progress(
      "Warning: EHOS sends mail through #{Refusal.shown(host)}:#{port} with no SMTP user. If " <>
        "the relay admits the server by its address, it admits each application on the server. " <>
        "An application that names #{Refusal.shown(host)} under needs.egress can then send as " <>
        "anyone in the domain of the company, outside its mail agreement. If applications of " <>
        "others run here, give EHOS a user of the relay (--smtp-username, with SMTP_PASSWORD). " <>
        "Then make the relay require that user, not the address of the server."
    )

    :ok
  end

  def warn_relay(_mail), do: :ok

  # DNS names are compared without case.
  defp held?(running, mail, user),
    do:
      is_map(running) and
        String.downcase(running["smtp"]["host"]) == String.downcase(mail["smtp"]["host"]) and
        running["smtp"]["username"] == user

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
    |> Enum.map_join(fn {key, value} -> " #{option(key)} #{EhosPlatform.Shell.word(value)}" end)
  end

  defp given_options(given),
    do: given |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &option/1)

  defp option("host"), do: "--smtp-host"
  defp option("port"), do: "--smtp-port"
  defp option("username"), do: "--smtp-username"
  defp option("from"), do: "--mail-from"

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
          "How long a sign-in of a person to an application lasts after the person signs in at " <>
            "EHOS. Format: hours or days, such as 12h or 30d, at most 366d. By default the value " <>
            "that EHOS uses now, else 12h."
      ],
      sign_in_idle: [
        long: "--sign-in-idle",
        value_name: "DURATION",
        help:
          "How long such a sign-in lasts when the person does not use it, at most the absolute " <>
            "limit. Format: hours or days. By default the value that EHOS uses now, else 1h."
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
         "EHOS #{version} has no sign-in limits to set: before #{@sign_in_since}, they are " <>
           "always 12h and 1h. Leave out --sign-in-absolute and --sign-in-idle, or install " <>
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
         "--sign-in-#{key} must be whole hours or days, and #{inspect(value)} is not. " <>
           "Give a value such as 12h or 30d."}
    end
  end

  # As the chart holds them (eh-os D-113), with its defaults for a value left out. A value not
  # given is named as the running EHOS's or the default, so no message blames an option left out.
  defp within(limits, given) do
    absolute = Map.get(limits, "absolute", "12h")
    idle = Map.get(limits, "idle", "1h")

    cond do
      seconds(absolute) > 366 * 86_400 ->
        {:error, :invalid,
         "#{capital(named("absolute", absolute, given, limits))} must be at most 366d. " <>
           "Give --sign-in-absolute of 366d or less."}

      seconds(idle) > seconds(absolute) ->
        {:error, :invalid,
         "#{capital(named("idle", idle, given, limits))} must be at most " <>
           "#{named("absolute", absolute, given, limits)}. Give a shorter --sign-in-idle or " <>
           "a longer --sign-in-absolute."}

      true ->
        :ok
    end
  end

  defp named(key, value, given, limits) do
    cond do
      Map.has_key?(given, key) -> "--sign-in-#{key} (#{value})"
      Map.has_key?(limits, key) -> "the #{key} limit that EHOS uses now (#{value})"
      true -> "the default #{key} limit (#{value})"
    end
  end

  defp capital(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp seconds(value) do
    {number, unit} = Integer.parse(value)
    number * if(unit == "d", do: 86_400, else: 3_600)
  end

  @doc """
  Installs. `opts` may name, for tests, `:install` (the module that does the work,
  `EhosPlatform.Install` by default), `:home` (`~/.ehos`), `:config_dir`, `:runner`, and
  `Ehosctl.GitHub`'s options.
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
         {:ok, allowed_domains} <-
           allowed_domains(parsed, installed.allowed_domains, wanted["version"]),
         :ok <-
           password_given(
             mail,
             installed.mail,
             Ehosctl.SystemEnv.current().all(),
             parsed.flags[:no_mail] == true
           ),
         :ok <- warn_relay(mail),
         {:ok, done} <-
           install(
             name,
             wanted,
             parsed.options[:host] || installed.host,
             opts
             |> Keyword.put(:sign_in, sign_in)
             |> Keyword.put(:four_eyes, four_eyes)
             |> Keyword.put(:mail, mail)
             |> Keyword.put(:allowed_domains, allowed_domains)
             |> Keyword.merge(switch(parsed))
             |> Keyword.put(:public_certificates, parsed.flags[:public_certificates] == true)
             |> Keyword.put(:skip_port_53_check, parsed.flags[:skip_port_53_check] == true)
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
      EhosPlatform.Install.tunnel_address(name: name, home: Ehosctl.Server.home(opts))

    if given == nil and old != nil and new != nil and old != new do
      {:error, :invalid,
       "EHOS on #{name} serves its console at #{host}, which names #{old}, but the server is at " <>
         "#{new} now. To move the console and the address of each application, " <>
         "#{remedy.("--host #{EhosPlatform.Install.sslip_host(new)}")}. ehosctl changed nothing."}
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
      EhosPlatform.Shell.word(Path.join([Ehosctl.Server.home(opts), name, "kubeconfig"]))

    helm = "helm --kubeconfig #{kubeconfig} --kube-context ehos-#{name} -n ehos-system"

    # Interrupted with nothing deployed before it, as a first install can be, it is removed;
    # over a deployed revision, it is rolled back to that one.
    way_out =
      if installed.running == :none,
        do: "Run `#{helm} uninstall ehos` to remove it, because nothing ran before it",
        else: "Run `#{helm} rollback ehos REVISION`, with the last deployed revision, to end it"

    {:error, :failed,
     "The last change to EHOS on #{name}, revision #{last.revision} of Helm, is " <>
       "#{Refusal.shown(status)} (#{Refusal.shown(last.description)}). An install or upgrade " <>
       "is running, or one stopped before it ended. Wait for it to end. If it stopped, " <>
       "`#{helm} history ehos` shows the revisions. #{way_out}. Then run this command " <>
       "again. ehosctl changed nothing."}
  end

  def settled(_installed, _name, _opts), do: :ok

  @doc "A line that says the release's last revision failed, or nothing."
  @spec failed_before(Platform.installed()) :: String.t()
  def failed_before(%{last: %{status: "failed"} = last}),
    do:
      "The last attempt, revision #{last.revision} of Helm, failed " <>
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
    env = Ehosctl.SystemEnv.current().all()

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
                   allowed_domains: Keyword.get(opts, :allowed_domains),
                   # A password left in the shell is not sent where --no-mail stops the mail.
                   smtp_password: if(Keyword.get(opts, :mail), do: env["SMTP_PASSWORD"]),
                   token: env["GHCR_TOKEN"],
                   username: env["GHCR_USERNAME"],
                   # eh-os#823: a server running k3s's Traefik is switched over SSH first.
                   passphrase: env["EHOS_STATE_PASSPHRASE"],
                   switch_traefik: Keyword.get(opts, :switch_traefik, false),
                   # eh-os D-158: an installation that has them keeps them without the flag.
                   public_certificates: Keyword.get(opts, :public_certificates, false),
                   skip_port_53_check: Keyword.get(opts, :skip_port_53_check, false),
                   ssh_key: Keyword.get(opts, :ssh_key),
                   progress: &progress/1
                 ]
             )
           ) do
      home = Ehosctl.Server.home(opts)
      {:ok, %{text: message <> "\n" <> signed_in(name, home, opts), json: nil}}
    end
  end

  defp base(name, opts),
    do: [
      name: name,
      home: Ehosctl.Server.home(opts),
      runner: Keyword.get(opts, :runner, Ehosctl.PlatformRunner),
      server_command: "ehosctl server",
      release_option: "--version",
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
           "from #{wanted["chart"]}. Nobody changes a release after it is published. Find out " <>
           "who changed it before you install anything from it. ehosctl changed nothing."}
  end

  defp may_install(%{"version" => running}, %{"version" => wanted}, name),
    do:
      {:error, :invalid,
       "#{name} runs EHOS #{Refusal.shown(running)}. An install does not move it to " <>
         "#{Refusal.shown(wanted)}. Run `ehosctl upgrade --installation #{name} --to #{wanted}`. " <>
         "ehosctl changed nothing."}

  defp may_install(:unknown, _wanted, name),
    do:
      {:error, :invalid,
       "#{name} runs an EHOS whose version ehosctl cannot read from the cluster, as " <>
         "`mix ehos.install` leaves it. Run `ehosctl upgrade --installation #{name}` to move it " <>
         "to a release. ehosctl changed nothing."}

  # The installation in `config.json`, for `login` (T-13, T-14): what `EhosPlatform.Install`
  # wrote beside the installation says its host and its CA. A failure here leaves EHOS running,
  # and says how to sign in without it.
  defp signed_in(name, home, opts) do
    dir = Path.join(home, name)
    env = Ehosctl.SystemEnv.current().all()
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env) end)
    ca_file = Path.join(dir, "ca.crt")

    host = installed_host(dir)
    url = if host, do: "https://#{host}", else: "https://<the console's host>"

    with true <- host != nil,
         {:ok, pem} when is_binary(pem) <-
           Ehosctl.TLS.ca_file_pem(%{"EHOSCTL_CA_FILE" => ca_file}),
         {:ok, read, _written} <-
           Config.update(
             config_dir,
             &{:ok, &1 |> Config.put(name, url) |> Config.put_ca(name, pem)}
           ) do
      replaced(read.installations[name], name, url) <>
        "Sign in with `ehosctl login --installation #{name}`. It trusts the CA of the installation."
    else
      _not_kept ->
        "Sign in with `EHOSCTL_CA_FILE=#{EhosPlatform.Shell.word(ca_file)} ehosctl login --installation #{name} " <>
          "#{url}`. ehosctl could not keep the installation in its configuration."
    end
  end

  # An installation of that name elsewhere is now this one, which the person should know: their
  # commands to it go here from now on.
  defp replaced(%{"url" => old}, name, url) when old != url,
    do: "The installation #{name} was at #{Ehosctl.Refusal.shown(old)}. It is at #{url} now.\n"

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

  # A line may hold what the server printed, as cloud-init's errors (ehos-tools#165).
  defp progress(line), do: IO.puts(:stderr, "==> " <> Ehosctl.Output.shown_lines(line))
end
