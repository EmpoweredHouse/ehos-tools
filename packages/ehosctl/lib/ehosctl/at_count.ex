defmodule Ehosctl.AtCount do
  @moduledoc """
  The ephemeral environments that hold a count, as EHOS names them when it refuses one more
  (`too_many_for_application`, `too_many_ephemeral`; eh-os
  [D-156](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0156-a-person-chooses-which-build-runs-in-an-ephemeral-environment-and-the-template-previews-a-pull-request-only-when-its-repository-turns-previews-on.md),
  [`docs/environments-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/environments-api.md#at-the-count)):
  `cap`, the maximum; `environments`, at most 20 of those the caller may read, each with its
  name, application, expiry and the build it runs where the caller may read it; and `more`, how
  many others the caller may read. A pipeline gets the maximum alone, or with its own
  environment.

  `held/1` keeps the fields `ehosctl` reads, each of its type, so nothing else EHOS's answer holds
  reaches a script under `--json` (ehos-tools#364); `said/2` is what follows EHOS's sentence for a
  person, as the console's deploy page lists them. What a build's run stated, a pull request's
  number and title, is printed as stated: EHOS does not check it.
  """

  alias Ehosctl.Builds
  alias Ehosctl.Failure
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @codes ~w(too_many_for_application too_many_ephemeral)
  @title_shown 60
  # EHOS lists at most this many; more from an EHOS that sends them are counted in `more`, so
  # what is printed, under `--json` too, stays bounded.
  @listed_most 20

  @doc """
  `error`, a refusal of EHOS's (`Ehosctl.Refusal.ehos/2`), with what `body` names at the count when
  its code is one of a count: its sentence followed by the environments, and, for `--json`, the
  fields `held/1` keeps beside the code. Any other error as it is.
  """
  @spec added(Refusal.error(), term()) :: Refusal.error()
  def added({:error, kind, message, %{"code" => code} = refusal}, body) when code in @codes do
    held = held(body)

    {:error, kind, Failure.added(message, said(code, held)),
     held |> Map.merge(refusal) |> Map.put("message", message)}
  end

  def added(error, _body), do: error

  @doc """
  The fields of a refusal at the count that `ehosctl` reads, each of its type: `cap`,
  `environments` and `more`, as EHOS gave them, and none that EHOS did not give, as an EHOS before
  D-156 does not. An environment of another shape is left out, and past the 20 EHOS lists, one is
  counted in `more`.

      iex> Ehosctl.AtCount.held(%{"error" => "too_many_ephemeral", "cap" => 6, "more" => 0})
      %{"cap" => 6, "more" => 0}
  """
  @spec held(term()) :: Output.refusal()
  def held(%{} = body) do
    listed = listed(body["environments"])

    %{}
    |> maybe_put("cap", count(body["cap"]))
    |> maybe_put(
      "environments",
      listed && Enum.map(Enum.take(listed, @listed_most), &environment/1)
    )
    |> maybe_put("more", with_cut(count(body["more"]), listed))
  end

  def held(_body), do: %{}

  @doc """
  What follows EHOS's sentence for a person, from what `held/1` kept: a table of the
  environments, how many more the person may read, who can remove one at the installation's
  count, and how to remove one. Nothing when EHOS listed none, as for a pipeline.

      iex> Ehosctl.AtCount.said("too_many_for_application", %{"cap" => 3, "environments" => []})
      ""
  """
  @spec said(String.t(), Output.refusal()) :: String.t()
  def said(code, %{"environments" => [_ | _] = environments} = held) do
    Enum.join(
      [
        "",
        "These ephemeral environments count toward the maximum#{of(held["cap"])}:",
        table(environments)
      ] ++
        more(held["more"]) ++
        who_frees(code) ++
        ["Run `ehosctl env remove ENVIRONMENT` to remove one."],
      "\n"
    )
  end

  def said(_code, _held), do: ""

  defp of(cap) when is_integer(cap), do: " of #{cap}"
  defp of(_cap), do: ""

  defp table(environments) do
    environments
    |> Enum.map(fn env ->
      %{
        "ENVIRONMENT" => Refusal.shown(env["name"]),
        "APPLICATION" => Refusal.named(env["application"]),
        "EXPIRES" => if(env["expires_at"], do: Output.date(env["expires_at"]), else: "never"),
        "BUILD" => build(env["build"])
      }
    end)
    |> Output.table(["ENVIRONMENT", "APPLICATION", "EXPIRES", "BUILD"])
  end

  # The build as its pull request's run stated it, else the ref GitHub's token named, else the
  # ref a person stated, else its id. None where EHOS gave none: no deployment there names a build,
  # or the person may not read the builds of its application.
  defp build(%{"stated" => %{"pull_request" => %{"number" => number} = pull_request}})
       when is_integer(number),
       do: "pull request ##{number}#{title(pull_request["title"])}"

  defp build(%{"ref" => ref}) when is_binary(ref), do: Refusal.shown(ref)

  defp build(%{"stated" => %{"ref" => ref}}) when is_binary(ref),
    do: Refusal.shown(ref) <> " (stated)"

  defp build(%{"id" => id}), do: Refusal.shown(id)
  defp build(_none), do: Output.none()

  defp title(title) when is_binary(title) and title != "" do
    if String.length(title) > @title_shown,
      do: ": " <> Refusal.shown(String.slice(title, 0, @title_shown - 1)) <> "…",
      else: ": " <> Refusal.shown(title)
  end

  defp title(_title), do: ""

  defp more(more) when is_integer(more) and more > 0,
    do: [
      "#{more} more that you can read also #{if more == 1, do: "counts", else: "count"}. " <>
        "Run `ehosctl env list` to see all of them."
    ]

  defp more(_more), do: []

  # As the deploy page says it: at the installation's count, the others may be other
  # applications', which the person may not be able to remove.
  defp who_frees("too_many_ephemeral"),
    do: [
      "Other applications can hold ephemeral environments that you cannot remove. A person " <>
        "with the role ehos.platform_operator can remove any of them."
    ]

  defp who_frees(_code), do: []

  defp listed(environments) when is_list(environments),
    do: Enum.filter(environments, &environment?/1)

  defp listed(_environments), do: nil

  defp environment?(%{"name" => name} = env) when is_binary(name),
    do:
      text_or_nil?(env["application"]) and text_or_nil?(env["expires_at"]) and
        (is_nil(env["build"]) or Builds.build?(env["build"]))

  defp environment?(_env), do: false

  defp environment(env) do
    %{
      "name" => env["name"],
      "application" => env["application"],
      "expires_at" => env["expires_at"],
      "build" => env["build"] && Builds.kept(env["build"])
    }
  end

  defp with_cut(more, listed) when is_list(listed) and length(listed) > @listed_most,
    do: (more || 0) + length(listed) - @listed_most

  defp with_cut(more, _listed), do: more

  defp count(count) when is_integer(count) and count >= 0, do: count
  defp count(_count), do: nil

  defp text_or_nil?(value), do: is_nil(value) or is_binary(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
