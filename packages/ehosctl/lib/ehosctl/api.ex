defmodule Ehosctl.Api do
  @moduledoc """
  Calls to EHOS's API. What it tells a person's terminal about them
  ([eh-os `docs/terminal-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/terminal-api.md)):
  the roles they hold (`GET /api/v1/me/roles`) and the applications they may use, where each one is
  and what it grants them (`GET /api/v1/me/applications`); and for the commands that manage what the
  console's pages manage, a read (`read/3`) and a change (`write/4`) of any of its routes.

  Each call carries a credential for EHOS's API from `Ehosctl.Credentials.fetch/3`, and a refusal
  is an error of its kind (`Ehosctl.Refusal.ehos/2`). Takes the options a command is handed.
  """

  alias Ehosctl.Config
  alias Ehosctl.Credentials
  alias Ehosctl.HTTP
  alias Ehosctl.Refusal

  @typedoc """
  One application in one environment where the person holds a role: `"application"`,
  `"environment"`, `"audience"`, `"address"`, `"roles"`, and `"capabilities"`, each with its
  `"name"`, `"label"` and `"kind"` (`"command"`, `"query"` or `"record"`).
  """
  @type application :: %{String.t() => term()}

  @type error :: {:error, Ehosctl.Output.kind(), String.t()}

  @kinds ~w(command query record)

  @doc "The roles bound to the person and to their agents, as `GET /api/v1/me/roles` lists them."
  @spec roles({Config.name(), Config.installation()}, keyword()) :: {:ok, [map()]} | error()
  def roles(installation, opts) do
    with {:ok, body} <- read(installation, "/api/v1/me/roles", opts) do
      case body do
        %{"roles" => roles} when is_list(roles) ->
          if Enum.all?(roles, &role?/1), do: {:ok, roles}, else: unexpected(installation)

        _other ->
          unexpected(installation)
      end
    end
  end

  @doc """
  The applications the person may use, each in one environment, as
  `GET /api/v1/me/applications` lists them. An entry whose address is not an `https` URL (`http`
  too under `allow_http: true`, for the tests) is refused as an answer EHOS would not give.
  """
  @spec applications({Config.name(), Config.installation()}, keyword()) ::
          {:ok, [application()]} | error()
  def applications(installation, opts) do
    with {:ok, body} <- read(installation, "/api/v1/me/applications", opts) do
      case body do
        %{"applications" => entries} when is_list(entries) ->
          if Enum.all?(entries, &application?(&1, opts)),
            do: {:ok, entries},
            else: unexpected(installation)

        _other ->
          unexpected(installation)
      end
    end
  end

  @doc """
  The entry of `applications` for `application` in `environment`. When `environment` is `nil`,
  the one environment where the person holds a role in it; when they hold one in several, an
  error of kind `:invalid` that names them. An application or environment where they hold none
  is of kind `:refused`, as the credential for it would be.
  """
  @spec choose([application()], String.t(), String.t() | nil) :: {:ok, application()} | error()
  def choose(applications, application, environment) do
    entries = Enum.filter(applications, &(&1["application"] == application))
    environments = Enum.map(entries, & &1["environment"])
    shown = Refusal.shown(application)

    case {entries, environment} do
      {[], _environment} ->
        {:error, :refused,
         "None of your roles is bound in #{shown}. Run `ehosctl apps` to see the applications " <>
           "you may use."}

      {[entry], nil} ->
        {:ok, entry}

      {_several, nil} ->
        {:error, :invalid,
         "You hold roles in #{shown} in #{list(environments)}. Name one with --env."}

      {entries, environment} ->
        case Enum.find(entries, &(&1["environment"] == environment)) do
          nil ->
            {:error, :refused,
             "None of your roles is bound in #{shown} in #{Refusal.shown(environment)}; " <>
               "you hold some in #{list(environments)}."}

          entry ->
            {:ok, entry}
        end
    end
  end

  defp list(names), do: names |> Enum.map(&Refusal.shown/1) |> Enum.join(", ")

  @doc """
  The body of `GET path`, a JSON object answered 200, or the refusal of whatever else EHOS's API
  answered, or why it did not.
  """
  @spec read({Config.name(), Config.installation()}, String.t(), keyword()) ::
          {:ok, map()} | error()
  def read(installation, path, opts) do
    case answer(installation, :get, path, nil, opts) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, answer} -> refusal(answer, installation)
      {:error, kind, message, :sent} -> {:error, kind, message}
      error -> error
    end
  end

  @doc """
  Sends a change, `{method, path, body}`, and says what EHOS says was done, else its refusal.

  `expect` holds the `:status` and the `:key` of a success's body, `:valid?`, whether the value
  under it is what was asked for, `:only`, the fields of it that are printed, under `--json` too,
  so nothing else an answer holds reaches a script, and `:look`, the command that shows whether a
  change was done. `said` turns the value into words.

  A change that went unanswered, or a gateway's 5xx without EHOS's code, may have been done; one
  EHOS answered with a success `ehosctl` cannot read was done; and one answered for something other
  than what was asked did something: each way the person is told to look.
  """
  @spec write(
          keyword(),
          {:post | :patch | :delete, String.t(), term()},
          keyword(),
          (map() -> String.t())
        ) :: {:ok, Ehosctl.Output.t()} | error()
  def write(opts, {method, path, body}, expect, said) do
    installation = Keyword.fetch!(opts, :installation)
    status = Keyword.fetch!(expect, :status)
    key = Keyword.fetch!(expect, :key)
    look = Keyword.fetch!(expect, :look)

    case answer(installation, method, path, body, opts) do
      {:ok, %{status: ^status, body: %{^key => value}}} ->
        if expect[:valid?].(value) do
          value = expect[:only].(value)
          {:ok, %{text: said.(value), json: %{key => value}}}
        else
          {:error, kind, message} = unexpected(installation)

          {:error, kind,
           message <>
             " It answered that something was done, but not as what was asked: run #{look} " <>
             "to see what was done."}
        end

      {:ok, %{status: answered}} when answered in 200..299 ->
        done_unread(installation, look)

      {:ok, %{status: answered} = answer} when answered >= 500 ->
        {:error, kind, message} = refusal(answer, installation)

        if coded?(answer.body),
          do: {:error, kind, message},
          else: {:error, kind, message <> maybe_done(look)}

      {:ok, answer} ->
        refusal(answer, installation)

      {:error, kind, message, :sent} ->
        {:error, kind, message <> maybe_done(look)}

      error ->
        error
    end
  end

  defp maybe_done(look), do: " It may have been done: run #{look} to see."

  defp done_unread(installation, look) do
    {:error, kind, message} = unexpected(installation)
    {:error, kind, message <> " It said it was done: run #{look} to see."}
  end

  @doc """
  Sends `method` to `path` of EHOS's API with a credential for it, and `body`
  (`Ehosctl.HTTP.request/5`'s), and returns the answer whatever its status, or why none came:
  `{:error, kind, message, :sent}` when the request was sent and no answer came, so it may have
  been done.
  """
  @spec answer(
          {Config.name(), Config.installation()},
          :get | :post | :patch | :delete,
          String.t(),
          term(),
          keyword()
        ) :: {:ok, HTTP.answer()} | error() | {:error, Ehosctl.Output.kind(), String.t(), :sent}
  def answer({_name, installation} = named, method, path, body, opts) do
    with {:ok, credential} <- Credentials.fetch(named, :ehos, opts) do
      HTTP.request(method, installation["url"] <> path, credential, body, opts)
    end
  end

  @doc """
  An answer of EHOS's API that is not what was asked for, as an error: a success that is not
  JSON as an answer `ehosctl` cannot read, any other its refusal (`Ehosctl.Refusal.ehos/2`).
  """
  @spec refusal(HTTP.answer(), {Config.name(), Config.installation()}) :: error()
  def refusal(%{status: status}, installation) when status in 200..299,
    do: unexpected(installation)

  def refusal(answer, {_name, installation}), do: Refusal.ehos(answer, installation["url"])

  defp role?(%{"role" => role, "held_by" => %{"kind" => kind, "name" => name}} = entry),
    do:
      is_binary(role) and kind in ["person", "agent"] and is_binary(name) and
        nil_or_text?(entry["application"]) and nil_or_text?(entry["environment"])

  defp role?(_entry), do: false

  defp application?(%{} = entry, opts) do
    texts = ~w(application environment audience address)

    Enum.all?(texts, &(is_binary(entry[&1]) and entry[&1] != "")) and
      address?(entry["address"], opts) and is_list(entry["roles"]) and
      Enum.all?(entry["roles"], &is_binary/1) and is_list(entry["capabilities"]) and
      Enum.all?(entry["capabilities"], &capability?/1)
  end

  defp application?(_entry, _opts), do: false

  # A name that would leave its place in the path (`.`, `..`) is not one EHOS gives. Any kind is
  # read, so that one a later EHOS adds is said to need a later `ehosctl` (`known_kind?/1`),
  # rather than making every application unreadable.
  defp capability?(%{"name" => name, "kind" => kind}) when is_binary(name) and is_binary(kind),
    do: name not in ["", ".", ".."]

  defp capability?(_capability), do: false

  @doc "Whether this version of `ehosctl` can call a capability of `kind`."
  @spec known_kind?(String.t()) :: boolean()
  def known_kind?(kind), do: kind in @kinds

  # The address the credential is sent to, so nothing but an origin over https, with an optional
  # path, is taken from EHOS's answer.
  defp address?(address, opts) do
    schemes = if opts[:allow_http], do: ["https", "http"], else: ["https"]

    case URI.new(address) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        scheme in schemes and Ehosctl.Output.printable?(address)

      _ ->
        false
    end
  end

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  @doc """
  Whether a body is one of EHOS's own refusals, with its code: a 5xx without one came from
  something in front of EHOS, a gateway, possibly after EHOS did what was asked.
  """
  @spec coded?(term()) :: boolean()
  def coded?(body), do: is_map(body) and is_binary(body["error"])

  @doc "An answer from `installation` that `ehosctl` cannot read, as an error of kind `:failed`."
  @spec unexpected({Config.name(), Config.installation()}) :: error()
  def unexpected({_name, installation}),
    do: {:error, :failed, "#{installation["url"]} answered with something ehosctl cannot read."}
end
