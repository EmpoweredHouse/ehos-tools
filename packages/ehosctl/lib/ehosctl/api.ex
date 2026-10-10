defmodule Ehosctl.Api do
  @moduledoc """
  What EHOS's API tells a person's terminal about them
  ([eh-os `docs/terminal-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/terminal-api.md)):
  the roles they hold (`GET /api/me/roles`) and the applications they may use, where each one is
  and what it grants them (`GET /api/me/applications`).

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

  @doc "The roles bound to the person and to their agents, as `GET /api/me/roles` lists them."
  @spec roles({Config.name(), Config.installation()}, keyword()) :: {:ok, [map()]} | error()
  def roles(installation, opts) do
    with {:ok, body} <- get(installation, "/api/me/roles", opts) do
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
  `GET /api/me/applications` lists them. An entry whose address is not an `https` URL (`http`
  too under `allow_http: true`, for the tests) is refused as an answer EHOS would not give.
  """
  @spec applications({Config.name(), Config.installation()}, keyword()) ::
          {:ok, [application()]} | error()
  def applications(installation, opts) do
    with {:ok, body} <- get(installation, "/api/me/applications", opts) do
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

  defp get({_name, installation} = named, path, opts) do
    url = installation["url"]

    with {:ok, credential} <- Credentials.fetch(named, :ehos, opts),
         {:ok, answer} <- HTTP.request(:get, url <> path, credential, nil, opts) do
      case answer do
        %{status: 200, body: %{} = body} -> {:ok, body}
        %{status: 200} -> unexpected(named)
        answer -> Refusal.ehos(answer, url)
      end
    else
      {:error, kind, message, :sent} -> {:error, kind, message}
      error -> error
    end
  end

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

  defp unexpected({_name, installation}),
    do: {:error, :failed, "#{installation["url"]} answered with something ehosctl cannot read."}
end
