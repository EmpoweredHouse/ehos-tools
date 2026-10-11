defmodule Ehosctl.Login do
  @moduledoc """
  `ehosctl login [URL]`: signs a person in to an installation of EHOS through their browser
  (eh-os D-89).

  With a URL, the installation at it is added, or updated when one has that URL, under
  `--installation NAME` or a name proposed from its host, and becomes the current one (T-07).
  Without one, the person signs in again to the installation `--installation`,
  `EHOSCTL_INSTALLATION` or the current one names, which is what "Run `ehosctl login`" in
  eh-os's refusals means.

  The browser is sent to EHOS's log-in page and comes back to `ehosctl` on the loopback address
  (`Ehosctl.SignIn.Loopback`); the password is typed into EHOS's page alone. What it obtains is
  kept by `Ehosctl.Credentials.keep/5` (T-08).
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Config
  alias Ehosctl.Credentials
  alias Ehosctl.Output
  alias Ehosctl.SignIn
  alias Ehosctl.SignIn.Loopback

  # How long the person has to sign in in the browser.
  @timeout_ms 5 * 60 * 1000

  # Labels of a host that name no installation: `ehos.staging.example.com` is `staging`.
  @generic_labels ~w(ehos www console)

  @impl Ehosctl.Command
  def name, do: :login

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def chooses_installation?, do: true

  @impl Ehosctl.Command
  def spec do
    [
      about: "Sign in to an installation of EHOS, through your browser.",
      args: [
        url: [
          value_name: "URL",
          required: false,
          help:
            "The installation's address, such as https://ehos.example.com. Without it, sign " <>
              "in again to the current installation, or the one --installation names."
        ]
      ],
      flags: Output.json_flag()
    ]
  end

  @doc """
  Signs in. Besides `Ehosctl.Credentials`' options, `opts` may name `:open_browser`, a function
  of the URL to send the browser to, `:timeout` in milliseconds, and, for the tests' fake EHOS
  alone, `allow_http: true`.
  """
  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    config_dir = Keyword.get_lazy(opts, :config_dir, fn -> Config.dir(env) end)

    with {:ok, config} <- Config.read(config_dir),
         {:ok, name, url} <-
           target(config, parsed.args[:url], parsed.options[:installation], env, opts),
         {:ok, provider} <- SignIn.provider(url, opts),
         {:ok, tokens} <- browse(provider, name, opts),
         {:ok, sign_in} <- Credentials.keep(name, url, tokens, SignIn.endpoints(provider), opts) do
      person = sign_in["email"] || sign_in["subject"]
      # As `whoami` says it: unrenewed for three days comes before the seven days.
      until = Credentials.until(sign_in, %{renewed_at: DateTime.utc_now(:second)})

      {:ok,
       %{
         text: "Signed in to #{name} (#{url}) as #{person}, until #{Output.date(until)}.",
         json: %{
           installation: name,
           url: url,
           subject: sign_in["subject"],
           email: sign_in["email"],
           until: DateTime.to_iso8601(until)
         }
       }}
    end
  end

  @doc """
  The installation to sign in to, as a name and a URL: see the module's documentation. The URL
  is checked by `Ehosctl.SignIn.origin/1`.
  """
  @spec target(Config.t(), String.t() | nil, Config.name() | nil, map(), keyword()) ::
          {:ok, Config.name(), String.t()} | {:error, Output.kind(), String.t()}
  def target(config, url, flag, env, opts \\ [])

  def target(config, nil, flag, env, _opts) do
    case Config.select(config, flag, env) do
      {:ok, {name, installation}} ->
        {:ok, name, installation["url"]}

      {:error, _kind, message} ->
        {:error, :invalid, "#{message}; name the installation's address: ehosctl login URL"}
    end
  end

  def target(config, url, flag, _env, opts) do
    with {:ok, url} <- SignIn.origin(url, Keyword.take(opts, [:allow_http])) do
      name = flag || Config.named_at(config, url) || propose(url)
      known = config.installations[name]

      cond do
        not Config.valid_name?(name) ->
          {:error, :invalid,
           "#{inspect(name)} cannot name an installation: lowercase letters, digits and dashes, " <>
             "starting with a letter"}

        is_nil(flag) and known != nil and known["url"] != url ->
          {:error, :invalid,
           "an installation named #{name} is at #{known["url"]}; " <>
             "name this one with --installation NAME"}

        true ->
          {:ok, name, url}
      end
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
  defp browse(provider, name, opts) do
    open_browser = Keyword.get(opts, :open_browser, &Ehosctl.Browser.open/1)
    timeout = Keyword.get(opts, :timeout, @timeout_ms)

    with {:ok, listener} <- listen() do
      try do
        redirect_uri = Loopback.redirect_uri(listener)

        with {:ok, url, request} <- SignIn.authorization(provider, redirect_uri) do
          IO.puts(:stderr, """
          Opening your browser to sign in to #{name} (#{provider.issuer}).
          If it does not open, go to:

            #{url}
          """)

          open_browser.(url)

          case Loopback.await(listener, timeout, &answer(&1, provider, request)) do
            {:ok, result} ->
              result

            {:error, :timeout} ->
              {:error, :failed,
               "the sign-in was not finished in the browser in time; run `ehosctl login` again"}

            {:error, reason} ->
              {:error, :failed, "the browser could not come back: #{:inet.format_error(reason)}"}
          end
        end
      after
        Loopback.close(listener)
      end
    end
  end

  defp listen do
    case Loopback.open() do
      {:ok, listener} ->
        {:ok, listener}

      {:error, reason} ->
        {:error, :failed,
         "cannot listen on 127.0.0.1 for the browser: #{:inet.format_error(reason)}"}
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
           text: "This is not the sign-in ehosctl is waiting for.",
           hint: "If you did not just run ehosctl login, close this tab."
         }}

      {:ok, code} ->
        case SignIn.exchange(provider, code, request) do
          {:ok, tokens} ->
            {:done, {:ok, tokens},
             %{
               tone: :ok,
               title: "Signed in",
               text: "ehosctl is signed in to #{provider.issuer}.",
               hint: "You can close this tab and go back to the terminal."
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
      text: "The terminal says why.",
      hint: "You can close this tab."
    }
end
