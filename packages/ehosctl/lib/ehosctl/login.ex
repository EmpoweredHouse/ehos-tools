defmodule Ehosctl.Login do
  @moduledoc """
  `ehosctl login [URL]`: signs a person in to an installation of EHOS through their browser
  (eh-os D-89).

  With a URL, the installation at it is added, or updated when one has that URL, under
  `--installation NAME`, else the name the installation gives itself in its discovery document
  when no installation here has it, else a name proposed from its host, and becomes the current
  one (T-07). When an installation kept under one name gives itself another, the sign-in says so.
  Without one, the person signs in again to the installation `--installation`,
  `EHOSCTL_INSTALLATION` or the current one names, which is what "Run `ehosctl login`" in
  eh-os's refusals means.

  The browser is sent to EHOS's log-in page and comes back to `ehosctl` on the loopback address
  (`Ehosctl.SignIn.Loopback`); the password is typed into EHOS's page alone. What it obtains is
  kept by `Ehosctl.Credentials.keep/5` (T-08).

  The certificates `EHOSCTL_CA_FILE` names, when it is set, are kept beside the installation, and
  every later command to it trusts them with no variable set (T-14). Without the variable, a
  sign-in again trusts the CA kept for the installation, and keeps it.

  It then reads the installation's data CA and gateway CA, and keeps them from the first login on
  the machine (`Ehosctl.DataCa`, eh-os D-181). A CA with another key than the kept one is not
  taken, and the person is told so.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Config
  alias Ehosctl.Credentials
  alias Ehosctl.DataCa
  alias Ehosctl.Failure
  alias Ehosctl.Output
  alias Ehosctl.SignIn
  alias Ehosctl.SignIn.Loopback
  alias EhosPlatform.Shell

  # How long the person has to sign in in the browser.
  @timeout_ms 5 * 60 * 1000

  # Labels of a host that name no installation: `ehos.staging.example.com` is `staging`.
  @generic_labels ~w(ehos www console)

  @impl Ehosctl.Command
  def name, do: :login

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :sign_in

  @impl Ehosctl.Command
  def summary, do: "Sign in to an installation in your browser."

  @impl Ehosctl.Command
  def chooses_installation?, do: true

  @impl Ehosctl.Command
  def spec do
    [
      about: "Sign in to an installation of EHOS in your browser.",
      args: [
        url: [
          value_name: "URL",
          required: false,
          help:
            "The address of the installation, such as https://ehos.example.com. If you give " <>
              "no address, ehosctl signs you in again to the current installation, or to the " <>
              "installation that --installation names."
        ]
      ],
      flags: Output.json_flag()
    ]
  end

  @doc """
  Signs in, sending the person to EHOS in `Ehosctl.Browser`. Besides `Ehosctl.Credentials`'
  options, `opts` may name `:timeout` in milliseconds.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    env = Ehosctl.SystemEnv.current().all()
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env) end)

    with {:ok, config} <- Config.read(config_dir),
         {:ok, name, url} <-
           target(config, parsed.args[:url], parsed.options[:installation], env),
         {:ok, given} <- Ehosctl.TLS.ca_file_pem(env),
         # The CA kept for an installation already at this URL; a new one, whose name may still
         # change below, has none kept.
         opts = trusting(opts, config, name, url, given),
         {:ok, provider} <- SignIn.current().provider(url, opts),
         given_itself = SignIn.installation_name(provider),
         {:ok, name} <-
           free(
             config,
             named(config, name, url, parsed.options[:installation], given_itself),
             url,
             parsed.options[:installation]
           ),
         {:ok, tokens} <-
           browse(
             provider,
             {name, login_command(parsed.args[:url], name)},
             parsed.flags[:json] == true,
             opts
           ),
         {:ok, sign_in, until, secret, warnings} <-
           Credentials.keep(name, url, tokens, SignIn.endpoints(provider), opts) do
      person = sign_in["email"] || sign_in["subject"]
      # After the outcome, and not under --json (`Ehosctl.Output.result/2`).
      warnings = warnings ++ data_cas(config_dir, name, opts)

      # T-30: where the refresh token is, as a value. The warning `Output.secrets/1` would give is
      # dropped: a file was warned of when it was kept, in T-08's warning, and T-30 gives none for
      # the system keychain.
      secrets = [secret]
      {values, _warned_when_kept} = Output.secrets(secrets)

      {:ok,
       %{
         text:
           Output.lines([
             Output.outcome(:done, "Signed in to #{name} as #{person}."),
             Output.values(
               [{"Address", url}, {"Until", Output.date(until)}] ++
                 also_named(name, given_itself) ++ values
             )
           ]),
         json:
           names_itself(
             %{
               installation: name,
               url: url,
               subject: sign_in["subject"],
               email: sign_in["email"],
               until: DateTime.to_iso8601(until),
               secrets: Output.secrets_json(secrets)
             },
             given_itself
           )
           |> with_warnings(warnings),
         warnings: warnings
       }}
    end
  end

  # A person signs in at the browser under --json too, and reads the JSON: a sign-in kept in a
  # file (D-89) or one left unended is said there, as words are not printed.
  defp with_warnings(json, []), do: json

  defp with_warnings(json, warnings), do: Map.put(json, :warnings, Output.warnings_json(warnings))

  # The data CA and the gateway CA, kept from the first login on this machine (`Ehosctl.DataCa`).
  # The sign-in stands whatever happens here: what could not be read is said, and read again at
  # the next login.
  defp data_cas(config_dir, name, opts) do
    with {:ok, config} <- Config.read(config_dir),
         %{} = installation <- config.installations[name],
         selected = {name, installation},
         opts = opts |> Keyword.put(:config_dir, config_dir) |> Config.trusting(selected),
         {:ok, outcomes} <- DataCa.refresh(selected, opts) do
      DataCa.warnings(name, outcomes)
    else
      nil -> []
      {:not_kept, {:error, _kind, message}} -> [data_cas_unkept(name, message)]
      {:error, _kind, message} -> [data_cas_unread(name, message)]
      {:error, _kind, message, _refusal} -> [data_cas_unread(name, message)]
    end
  end

  defp data_cas_unread(name, message),
    do:
      {"ehosctl could not read the data CA and the gateway CA of #{name}.",
       "A data session needs them. Reading them failed: " <> read_failed(name, message)}

  defp data_cas_unkept(name, message),
    do:
      {"ehosctl read the data CA and the gateway CA of #{name}, but could not keep them.",
       "A data session needs them. Keeping them in config.json failed: " <>
         read_failed(name, message)}

  # What the read answered, with its own advice when it has one, as checking the network before
  # signing in again; else signing in again, which reads them again.
  defp read_failed(name, %Failure{advice: nil, to_do: []} = failure),
    do: Failure.said(failure) <> again(name)

  defp read_failed(_name, %Failure{} = failure), do: Failure.sentence(failure)
  defp read_failed(name, message), do: message <> again(name)

  defp again(name), do: " Run `ehosctl login --installation #{name}` again before you open one."

  # A new installation, with no name given, is kept under the name it gives itself, so that
  # ehosctl and its console name it alike; unless an installation here has that name already.
  defp named(config, proposed, url, nil = _flag, given_itself)
       when is_binary(given_itself) do
    new? = is_nil(Config.named_at(config, url))
    free? = is_nil(config.installations[given_itself])
    if new? and free?, do: given_itself, else: proposed
  end

  defp named(_config, name, _url, _flag, _given_itself), do: name

  # Without --installation, a name another installation here is at is not taken from it: checked
  # once the name the installation gives itself is known, which may be free where the host's is not.
  defp free(config, name, url, nil = _flag) do
    case config.installations[name] do
      %{"url" => other} when other != url ->
        {:error, :invalid,
         "The installation #{name} is already at #{other}. Give this installation another " <>
           "name with --installation NAME."}

      _free_or_this ->
        {:ok, name}
    end
  end

  defp free(_config, name, _url, _flag), do: {:ok, name}

  defp also_named(name, given_itself) when is_binary(given_itself) and given_itself != name,
    do: [{"Its own name", given_itself}]

  defp also_named(_name, _given_itself), do: []

  # As the words say it: only when the installation is kept under another name than its own.
  defp names_itself(%{installation: name} = json, given_itself)
       when is_binary(given_itself) and given_itself != name,
       do: Map.put(json, :names_itself, given_itself)

  defp names_itself(json, _given_itself), do: json

  # The variable's CA is trusted through the variable, and kept; without it, the one kept for the
  # installation at this URL is trusted, and `keep/5` leaves what `config.json` holds when it
  # writes, rather than what it held before the browser: `ehosctl install` may have kept another
  # CA meanwhile. One kept for another URL is not: `put` drops it with the old URL.
  defp trusting(opts, config, name, url, given) do
    kept =
      case config.installations[name] do
        %{"url" => ^url, "ca" => pem} -> pem
        _other -> nil
      end

    opts = maybe_put(opts, :keep_ca, given)

    if is_nil(given) and kept,
      do: Keyword.put(opts, :ca, {name, kept}),
      else: Keyword.delete(opts, :ca)
  end

  @doc """
  The installation to sign in to, as a name and a URL: see the module's documentation. The URL
  is checked by `Ehosctl.SignIn.origin/1`. Whether another installation here is at the name is
  checked after discovery, which can name the installation otherwise.
  """
  @spec target(Config.t(), String.t() | nil, Config.name() | nil, map()) ::
          {:ok, Config.name(), String.t()} | {:error, Output.kind(), Ehosctl.Failure.message()}
  def target(config, nil, flag, env) do
    case Config.select(config, flag, env) do
      {:ok, {name, installation} = chosen} ->
        if Config.from_url?(chosen),
          do:
            {:error, :invalid,
             "EHOSCTL_URL names an installation that a GitHub Actions job uses with its own " <>
               "token. Nobody signs in to it. Run `ehosctl login URL` with the address of " <>
               "the installation."},
          else: {:ok, name, installation["url"]}

      {:error, _kind, message} ->
        {:error, :invalid, message}
    end
  end

  def target(config, url, flag, _env) do
    with {:ok, url} <- SignIn.origin(url) do
      name = flag || Config.named_at(config, url) || propose(url)

      if Config.valid_name?(name),
        do: {:ok, name, url},
        else:
          {:error, :invalid,
           "#{inspect(name)} is not a valid name for an installation. A name has lowercase " <>
             "letters, digits and dashes, and starts with a letter. Give another name with " <>
             "--installation NAME."}
    end
  end

  @doc """
  The name proposed for the installation at `url`, from its host: `local` on this machine, else
  the host's first label that is not a generic one.

      iex> Ehosctl.Login.propose("https://ehos.staging.example.com")
      "staging"

      iex> Ehosctl.Login.propose("https://ehos.localhost")
      "local"
  """
  @spec propose(String.t()) :: Config.name()
  def propose(url) do
    host = URI.parse(url).host

    if SignIn.loopback?(host) do
      "local"
    else
      label =
        host
        |> String.split(".")
        |> Enum.reject(&(&1 in @generic_labels))
        |> List.first("ehos")
        |> String.replace(~r/[^a-z0-9-]/, "-")
        |> String.trim("-")

      label = if label =~ ~r/\A[a-z]/, do: label, else: "ehos-" <> label
      label = label |> String.slice(0, 63) |> String.trim_trailing("-")
      if Config.valid_name?(label), do: label, else: "ehos"
    end
  end

  # The browser's part: send it to EHOS, and wait for it on the loopback address.
  # `again`, the command that signs in again, names the address when the person gave one: before a
  # first sign-in ends, no installation is kept under the name to find it by.
  defp browse(provider, {name, again}, json?, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout_ms)

    with {:ok, listener} <- listen(again) do
      try do
        redirect_uri = Loopback.redirect_uri(listener)

        with {:ok, url, request} <- SignIn.authorization(provider, redirect_uri) do
          # The address on a line of its own, to copy when no browser opens, under --json too: a
          # person reads it there. The steps are left out under --json.
          if not json?,
            do: Output.progress("Opening the browser to sign in to #{name} (#{provider.issuer})")

          Output.aside(
            Output.lines([
              "  If the browser does not open, go to this address:",
              "",
              "    " <> url
            ])
          )

          if not json?, do: Output.progress("Waiting for the sign-in in the browser")

          Ehosctl.Browser.current().open(url, [])

          case Loopback.await(listener, timeout, &answer(&1, provider, request)) do
            {:ok, result} ->
              result

            {:error, :timeout} ->
              {:error, :failed,
               Failure.new("You did not finish the sign-in in the browser in time.",
                 to_do: [again]
               )}

            {:error, reason} ->
              {:error, :failed,
               Failure.new(
                 "ehosctl did not receive the answer of the browser: " <>
                   "#{:inet.format_error(reason)}.",
                 to_do: [again]
               )}
          end
        end
      after
        Loopback.close(listener)
      end
    end
  end

  defp login_command(nil, name), do: "ehosctl login --installation #{name}"
  defp login_command(url, name), do: "ehosctl login #{Shell.word(url)} --installation #{name}"

  defp listen(again) do
    case Loopback.open() do
      {:ok, listener} ->
        {:ok, listener}

      {:error, reason} ->
        {:error, :failed,
         Failure.new(
           "127.0.0.1: ehosctl cannot listen there for the answer of the browser " <>
             "(#{:inet.format_error(reason)}).",
           to_do: [again]
         )}
    end
  end

  # What the browser is told, and what the command does next. The code is exchanged before the
  # browser is answered, so the page says how the sign-in ended.
  defp answer(params, provider, request) do
    case SignIn.callback(params, request, provider.issuer) do
      :ignore ->
        {:ignore,
         %{
           tone: :error,
           title: "Not this sign-in",
           text: "This is not the sign-in that ehosctl waits for.",
           hint: "If you did not run ehosctl login a moment ago, close this tab."
         }}

      {:ok, code} ->
        case SignIn.current().exchange(provider, code, request) do
          {:ok, tokens} ->
            {:done, {:ok, tokens},
             %{
               tone: :ok,
               title: "Signed in",
               text: "ehosctl is signed in to #{provider.issuer}.",
               hint: "Close this tab and go back to the terminal."
             }}

          error ->
            {:done, error, not_finished()}
        end

      error ->
        {:done, error, not_finished()}
    end
  end

  defp not_finished,
    do: %{
      tone: :error,
      title: "The sign-in did not finish",
      text: "The terminal shows the reason.",
      hint: "Close this tab."
    }

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
