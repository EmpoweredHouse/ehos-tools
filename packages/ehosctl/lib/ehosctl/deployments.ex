defmodule Ehosctl.Deployments do
  @moduledoc """
  An application's deployments in an environment, as the console's application page shows them,
  from `GET /api/v1/applications/:name/environments/:environment/deployments` (eh-os#413): the
  deployment in force with its state, the addresses the application is served at there, and the
  deployments and refusals before it, newest first. `ehosctl apps show` says each environment's
  state from it, and `follow/5` reads it until a deployment ends, for `ehosctl deploy`, which
  follows the deployment it made, and `ehosctl approve`, which follows the one an approval decides.

  Reading it needs `ehos.application.deploy` or `ehos.application.register` in the environment.
  An installation whose EHOS predates the route answers `{:lacking, message}`, so that a command
  can say what it cannot tell there rather than fail.
  """

  alias Ehosctl.Api
  alias Ehosctl.Config
  alias Ehosctl.Failure
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.Source
  alias EhosPlatform.Shell

  require Ehosctl.Api

  @typedoc """
  What the route answers, kept to the fields read: `"application"`, `"environment"`,
  `"addresses"`, `"in_force"` (a deployment or `nil`) and `"before"`, deployments and refusals
  (`"kind" => "refused"`), newest first.
  """
  @type history :: %{String.t() => term()}

  @typedoc """
  A deployment: `"kind" => "deployment"`, `"id"`, `"state"` (`pending`, `activating`, `active`,
  `failed`, `superseded` or `withdrawn`), `"image"`, `"manifest_digest"`, `"source"`, where it
  came from or `nil` (`Ehosctl.Source`), `"failure"`, `"by"` and `"at"`; from eh-os 0.14.0 on,
  `"promotion"`, the id of the promotion that brought it to production, and for one listed before
  the deployment in force `"next"`, the deployment after it and what that one `"changed"`
  (`"image"`, `"manifest"`, `"secrets"`, with the `"secrets"` it may name), each `nil` when EHOS
  gives none or one of another shape (eh-os#802).
  """
  @type deployment :: %{String.t() => term()}

  # The most entries of `before` asked for unless a caller asks for more: `deploy` follows the
  # newest deployment, and `apps show` reads the newest before the one in force.
  @limit 5

  @deployment ~w(kind id state image manifest_digest source failure by at)
  @next ~w(id state at changed secrets)
  @changes ~w(image manifest secrets)
  @refused ~w(kind id image digest by why at)

  # How often the deployment is read while it is followed, and for how long at most.
  @poll_ms 2_000
  @poll_max_ms 10_000
  # The most deployments EHOS lists in one answer.
  @listed_most 50
  @wait_ms 600_000
  @wait "#{div(@wait_ms, 60_000)} minutes"

  @doc """
  The deployments of `application` in `environment`, the `limit` newest before the one in force
  (EHOS takes 1 to 50), or `{:lacking, message}` when the installation's EHOS has no such route, or the refusal or
  error of the read. An answer for another application or environment, or of another shape, is
  one `ehosctl` cannot read. A name that would leave its place in the path (`.`, `..`), or names
  nothing, is refused before anything is sent.
  """
  @spec history(
          {Config.name(), Config.installation()},
          String.t(),
          String.t(),
          keyword(),
          pos_integer()
        ) :: {:ok, history()} | {:lacking, String.t()} | Api.error()
  def history(installation, application, environment, opts, limit \\ @limit) do
    case Enum.find([application, environment], &Api.is_nameless(&1)) do
      nil ->
        read(installation, application, environment, opts, limit)

      word ->
        {:error, :invalid,
         "#{Refusal.shown(word)} is not the name of an application or an environment."}
    end
  end

  defp read(installation, application, environment, opts, limit) do
    path =
      "/api/v1/applications/#{Api.segment(application)}/environments/#{Api.segment(environment)}" <>
        "/deployments?" <> URI.encode_query(limit: limit)

    case Api.read_if_routed(installation, path, opts) do
      {:ok, body} ->
        if history?(body, application, environment),
          do: {:ok, kept(body)},
          else: Api.unexpected(installation)

      other ->
        other
    end
  end

  @doc """
  The newest deployment before the one in force, when it was decided after it and failed: a
  deployment that failed is never in force, so this is what the latest attempt came to. `nil`
  otherwise, and when either moment cannot be read.
  """
  @spec failed_after(history()) :: deployment() | nil
  def failed_after(history) do
    newest = Enum.find(history["before"], &match?(%{"kind" => "deployment"}, &1))
    in_force = history["in_force"]

    with %{"state" => "failed"} <- newest,
         true <- is_nil(in_force) or after?(newest, in_force) do
      newest
    else
      _other -> nil
    end
  end

  # In EHOS's order: by the moment each was decided, then by id for two decided in the same one.
  defp after?(later, earlier) do
    with true <- is_binary(later["at"]) and is_binary(earlier["at"]),
         {:ok, later_at, _offset} <- DateTime.from_iso8601(later["at"]),
         {:ok, earlier_at, _offset} <- DateTime.from_iso8601(earlier["at"]) do
      case DateTime.compare(later_at, earlier_at) do
        :gt -> true
        :eq -> later["id"] > earlier["id"]
        :lt -> false
      end
    else
      _other -> false
    end
  end

  @doc "The deployment `id` in `history`, in force or before it, or `nil`."
  @spec find(history(), String.t()) :: deployment() | nil
  def find(history, id),
    do:
      Enum.find(
        [history["in_force"] | history["before"]],
        &match?(%{"kind" => "deployment", "id" => ^id}, &1)
      )

  @doc """
  Follows deployment `body["deployment"]` of `application` in `environment` until EHOS says how it
  ended, and prints each state it moves to as progress on stderr, as `ehosctl deploy` waits
  (eh-os#413): it reads the deployments there after two seconds and then further apart, up to ten
  seconds, and ends when the deployment is `active` (exit 0), `failed`, `superseded` or
  `withdrawn` (exit 1), or when ten minutes pass first (exit 5). A read EHOS did not answer is
  tried again until then; a refusal ends the wait, and is returned with how to look at the
  deployment later. Against an EHOS with no such route it says it cannot follow the deployment,
  and exits 0.

  `body` is what EHOS answered when it decided the deployment, kept to the fields read: under
  `--json` nothing is printed until the outcome, and then `body` with the deployment's last
  `state` and `failure`, the `outcome` and the `addresses`, in one document.
  """
  @spec follow(
          {Config.name(), Config.installation()},
          {String.t(), String.t()},
          map(),
          boolean(),
          keyword()
        ) :: non_neg_integer() | Api.error()
  def follow(installation, {application, env}, body, json?, opts) do
    # The wait is progress, on stderr: stdout keeps the outcome alone.
    say = if json?, do: fn _line -> :ok end, else: &Output.progress/1

    say.("Waiting until the deployment is active, for at most #{@wait}")

    deadline = Ehosctl.Clock.current().monotonic() + @wait_ms
    where = {installation, application, env}
    pause = @poll_ms

    where
    |> wait(body["deployment"], nil, {deadline, pause}, say, opts)
    |> outcome(body, where, json?)
  end

  # `seen` is the deployment and the history last read, `nil` before one was.
  defp wait({installation, application, env} = where, id, seen, timing, say, opts) do
    read =
      with {:ok, history} <- history(installation, application, env, opts),
           do: found(history, id, where, opts)

    case read do
      {:ok, deployment, history} ->
        if seen == nil or elem(seen, 0)["state"] != deployment["state"],
          do: say.("State of the deployment: #{Refusal.shown(deployment["state"])}")

        wait_moved(where, id, {deployment, history}, timing, say, opts)

      # A read EHOS did not answer, or answered that it could not now, is tried again until the
      # bound; a refusal is not, since EHOS records each read it refuses.
      error when elem(error, 0) == :error and elem(error, 1) == :unreachable ->
        again(where, id, seen, timing, say, opts, fn -> unreachable(seen, error) end)

      other ->
        other
    end
  end

  # The last deployment read, as still waited on, or the error when none was.
  defp unreachable(seen, error),
    do: if(seen, do: Tuple.insert_at(seen, 0, :waiting), else: error)

  defp wait_moved(where, id, {deployment, history} = seen, timing, say, opts) do
    case moved(deployment) do
      :waiting ->
        again(where, id, seen, timing, say, opts, fn ->
          {:waiting, deployment, history}
        end)

      moved ->
        {moved, deployment, history}
    end
  end

  # Reads further apart as the wait goes on: from `@poll_ms` growing by half each time, to
  # `@poll_max_ms`.
  # No pause runs past the bound, and no read starts after it.
  defp again(where, id, seen, {deadline, pause}, say, opts, ended) do
    left = deadline - Ehosctl.Clock.current().monotonic()

    if left > 0 do
      Ehosctl.Clock.current().sleep(min(pause, left))
    end

    if Ehosctl.Clock.current().monotonic() >= deadline do
      ended.()
    else
      longer = min(div(pause * 3, 2), @poll_max_ms)
      wait(where, id, seen, {deadline, max(longer, pause)}, say, opts)
    end
  end

  # The newest deployments are read, which hold the one just made unless more were decided after
  # it meanwhile: then as many as EHOS lists are read once, and if it is not among those either,
  # others have long since been decided after it.
  defp found(history, id, {installation, application, env}, opts) do
    case find(history, id) do
      nil ->
        with {:ok, more} <-
               history(installation, application, env, opts, @listed_most),
             do: found_in(more, id)

      deployment ->
        {:ok, deployment, history}
    end
  end

  defp found_in(more, id) do
    case find(more, id) do
      nil -> {:displaced, id}
      deployment -> {:ok, deployment, more}
    end
  end

  # EHOS's own state for it says how it ended. One decided after it is in force as soon as it is
  # decided, so whether it is in force does not: it may still become active, and stays in force
  # when the later one fails. A state a later EHOS adds is waited on, as `pending` and
  # `activating` are.
  defp moved(%{"state" => "active"}), do: :active
  defp moved(%{"state" => "failed"}), do: :failed
  defp moved(%{"state" => "superseded"}), do: :superseded
  defp moved(%{"state" => "withdrawn"}), do: :withdrawn
  defp moved(_deployment), do: :waiting

  # No command reads the deployments of an EHOS without their route: the console says the state.
  defp outcome({:lacking, message}, body, {_installation, application, env}, json?) do
    Output.result(
      %{
        text:
          Output.lines([
            "",
            Output.outcome(
              :warning,
              "ehosctl cannot follow the deployment in #{Refusal.shown(env)}: #{message}"
            ),
            "  Open the page of #{Refusal.shown(application)} in the console to see if it " <>
              "became active."
          ]),
        json: Map.put(body, "outcome", "not_followed")
      },
      json?
    )
  end

  defp outcome({:displaced, id}, body, {installation, application, env}, json?),
    do:
      ended(
        Map.put(body, "outcome", "displaced"),
        json?,
        :unreachable,
        Failure.new(
          "Deployment #{Refusal.shown(id)} is no longer among the newest deployments in " <>
            "#{Refusal.shown(env)}: EHOS decided others after it, and one may have replaced it.",
          advice: "To see what is in force there, run:",
          to_do: [history_command(application, env, installation)]
        )
      )

  # A read that failed, or was refused, while waiting: the deployment stands, whatever came of it.
  # Running the command again would decide another deployment, so a read that went unanswered
  # keeps no advice to; a sign-in to renew keeps its command, which decides nothing.
  defp outcome(
         {:error, :unreachable, _message} = error,
         body,
         {installation, app, env},
         _json?
       ),
       do: unanswered(error, body["deployment"], history_command(app, env, installation))

  defp outcome(
         {:error, :unreachable, _message, _refusal} = error,
         body,
         {installation, app, env},
         _json?
       ),
       do: unanswered(error, body["deployment"], history_command(app, env, installation))

  # A refused read is refused again by `apps history`, which sends it: the console says the state.
  defp outcome(error, body, {_installation, app, _env}, _json?)
       when elem(error, 0) == :error and elem(error, 1) == :refused,
       do:
         Refusal.added(
           error,
           " EHOS decided deployment #{Refusal.shown(body["deployment"])}. Open the page of " <>
             "#{Refusal.shown(app)} in the console to see its state."
         )

  defp outcome(error, body, {installation, app, env}, _json?)
       when elem(error, 0) == :error,
       do: Refusal.added(error, look(body["deployment"], history_command(app, env, installation)))

  defp outcome(
         {moved, deployment, history},
         body,
         {installation, application, env},
         json?
       ) do
    json =
      Map.merge(body, %{
        "state" => deployment["state"],
        "failure" => deployment["failure"],
        "outcome" => Atom.to_string(moved),
        "addresses" => history["addresses"]
      })

    id = Refusal.shown(deployment["id"])
    # As text; the command below takes the environment as the person gave it.
    shown_env = Refusal.shown(env)

    case moved do
      :active ->
        if not json?, do: later(history, deployment)

        Output.result(
          %{
            # After the decision `deploy` printed, a part of its own.
            text:
              Output.lines([
                "",
                Output.outcome(:done, "Deployment #{id} is active in #{shown_env}."),
                at(history["addresses"])
              ]),
            json: json
          },
          json?
        )

      :failed ->
        failure =
          if is_binary(deployment["failure"]),
            do: ": " <> Refusal.shown(deployment["failure"]),
            else: ". EHOS gave no reason"

        ended(json, json?, :failed, "Deployment #{id} failed in #{shown_env}#{failure}.")

      :superseded ->
        ended(
          json,
          json?,
          :failed,
          "Deployment #{id} was superseded in #{shown_env}: #{replaced(history, deployment)} " <>
            "replaced it."
        )

      # Its ephemeral environment was taken down while it rolled out (eh-os D-100), so it is not
      # in force, and never will be.
      :withdrawn ->
        ended(
          json,
          json?,
          :failed,
          "Deployment #{id} was withdrawn: EHOS removed #{shown_env} while the deployment rolled out."
        )

      :waiting ->
        ended(
          json,
          json?,
          :unreachable,
          Failure.new(
            "Deployment #{id} is still #{Refusal.shown(deployment["state"])} in #{shown_env} after " <>
              "#{@wait}. It can still become active or fail.",
            advice: "To see its state later, run:",
            to_do: [history_command(application, env, installation)]
          )
        )
    end
  end

  # The outcome is the document under `--json`, its exit code saying what it was; else a line on
  # stderr, as every error is.
  defp ended(json, true, kind, _message) do
    Output.result(%{text: "", json: json}, true)
    Output.code(kind)
  end

  defp ended(_json, false, kind, message), do: Output.error(kind, message, false)

  defp replaced(%{"in_force" => %{"id" => other}}, %{"id" => id}) when other != id,
    do: "deployment #{Refusal.shown(other)}"

  defp replaced(_history, _deployment), do: "another deployment"

  # Active, with another decided after it in force: that one may yet take its place.
  defp later(%{"in_force" => %{"id" => other} = in_force}, %{"id" => id}) when other != id,
    do:
      Output.warn(
        "EHOS decided deployment #{Refusal.shown(other)} after this one.",
        "That deployment is #{Refusal.shown(in_force["state"])} there, and can take the place " <>
          "of this one."
      )

  defp later(_history, _deployment), do: :ok

  defp at([]), do: nil

  defp at(addresses),
    do: Output.values([{"Address", Enum.map_join(addresses, "\n", &Refusal.shown/1)}])

  # The command that lists the deployments of `application` in `env`, at its installation: it needs
  # what the deployment needed, where `apps show` needs ehos.application.register.
  defp history_command(application, env, installation),
    do:
      Config.command(
        "ehosctl apps history #{Shell.word(application)} --env #{Shell.word(env)}",
        installation
      )

  # Running the command again would decide another deployment: what to do is to look at it.
  defp unanswered(error, id, command),
    do:
      Refusal.updated(
        error,
        &Failure.with_to_do(
          Failure.said(&1) <> " EHOS decided deployment #{Refusal.shown(id)}.",
          "To see its state, run:",
          [command]
        )
      )

  defp look(id, command),
    do:
      " EHOS decided deployment #{Refusal.shown(id)}." <>
        Output.offered(" Run `#{command}` to see its state.")

  defp history?(%{"application" => app, "environment" => env} = body, app, env),
    do:
      texts?(body["addresses"]) and (is_nil(body["in_force"]) or deployment?(body["in_force"])) and
        is_list(body["before"]) and Enum.all?(body["before"], &entry?/1)

  defp history?(_body, _app, _env), do: false

  # A kind a later EHOS adds is left out rather than making the history unreadable.
  defp entry?(%{"kind" => "deployment"} = deployment), do: deployment?(deployment)
  defp entry?(%{"kind" => "refused", "id" => id}), do: is_binary(id)
  defp entry?(%{"kind" => kind}), do: is_binary(kind)
  defp entry?(_entry), do: false

  defp deployment?(%{"kind" => "deployment", "id" => id, "state" => state} = deployment),
    do:
      is_binary(id) and is_binary(state) and
        (is_nil(deployment["failure"]) or is_binary(deployment["failure"]))

  defp deployment?(_deployment), do: false

  defp texts?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)

  # Kept to the fields read, so nothing else an answer holds reaches a script under `--json`.
  defp kept(body) do
    %{
      "application" => body["application"],
      "environment" => body["environment"],
      "addresses" => body["addresses"],
      "in_force" => body["in_force"] && deployment(body["in_force"]),
      "before" =>
        Enum.flat_map(body["before"], fn
          %{"kind" => "deployment"} = deployment -> [deployment(deployment)]
          %{"kind" => "refused"} = refused -> [Map.take(refused, @refused)]
          _other -> []
        end)
    }
  end

  defp deployment(deployment) do
    kept =
      deployment
      |> Map.take(@deployment)
      |> Source.keeping()

    # eh-os#802: absent from an older EHOS, and then left out rather than given as nil.
    kept
    |> keep_if(deployment, "promotion", &if(is_binary(&1), do: &1))
    |> keep_if(deployment, "next", &next/1)
  end

  defp keep_if(kept, deployment, key, keep) do
    case Map.fetch(deployment, key) do
      {:ok, value} -> Map.put(kept, key, keep.(value))
      :error -> kept
    end
  end

  # The next deployment as EHOS gives it, kept to its fields, or nil for one of another shape.
  defp next(%{"id" => id, "changed" => changed, "secrets" => secrets} = next)
       when is_binary(id) and is_list(changed) and is_list(secrets) do
    if Enum.all?(changed, &(&1 in @changes)) and Enum.all?(secrets, &is_binary/1) and
         Enum.all?([next["state"], next["at"]], &(is_nil(&1) or is_binary(&1))),
       do: Map.take(next, @next)
  end

  defp next(_next), do: nil
end
