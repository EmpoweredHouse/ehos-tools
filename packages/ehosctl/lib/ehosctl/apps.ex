defmodule Ehosctl.Apps do
  @moduledoc """
  `ehosctl apps`: the applications the person may use, each in an environment where they hold a
  role, with its address and what their roles grant there (`Ehosctl.Api.applications/2`). These
  are what `ehosctl credential` and `ehosctl call` reach.

  `ehosctl apps register | show | review`: an application's manifest kept as a version, its
  versions and what is in force in each environment, and what one changes against the version in
  force in an environment, through EHOS's API (eh-os
  [`docs/versions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/versions-api.md),
  D-32, D-52). Each needs `ehos.application.register`: for the application, or at the whole
  platform to register a new one, and in the environment to review there. EHOS decides and records
  each call, and its refusal is printed in its words. Only a deployment puts a version in force,
  `ehosctl deploy`, and in production a promotion's, asked for on the application's promotions
  page (eh-os D-154).

  `register` takes a utility service's `ehos.yaml` as well, a file named `.yaml` or `.yml`: it
  writes the manifest from the file as `ehosctl verify` writes it into the bundle
  (`Ehosctl.ServiceYaml`, eh-os D-175), and sends that, as the console's upload does.

  A version is named by its digest, or by the start of it the console shows (`sha256:` and 12
  digits), which the application's versions resolve.

  `show` also says each environment's deployment state, read from that environment's deployments
  (`Ehosctl.Deployments`, eh-os#413): one request for each. That is the state of the deployment
  in force, or `failed`, with its failure, when the newest deployment there failed. An
  environment whose deployments cannot be read is shown as `unknown`, with why; an installation
  whose EHOS predates the route is asked once. Under the table, where each deployment in force
  came from, for those EHOS names it for (`Ehosctl.Source`, eh-os D-129).

  `ehosctl apps history <application> --env E`: its deployments there, the one in force and those
  before it, each with what came after it (`Ehosctl.DeploymentHistory`, eh-os#802), the
  20 newest of each.

  `ehosctl apps sign-in list | agree | withdraw`: other applications' pages getting credentials
  for an application in an environment, as its environment tab agrees (`Ehosctl.Agreements`).
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Agreements
  alias Ehosctl.Api
  alias Ehosctl.Config
  alias Ehosctl.DeploymentHistory
  alias Ehosctl.Deployments
  alias Ehosctl.Failure
  alias Ehosctl.ManifestFile
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.Review
  alias Ehosctl.ServiceYaml
  alias Ehosctl.Source
  alias EhosPlatform.Shell

  require Ehosctl.Api

  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  # The start of a digest the console shows, and the least `ehosctl` resolves.
  @shortest 12
  # The most of a failure's words `show` prints beside its state; `--json` has them all.
  @failure_shown 60

  @again " EHOS may have kept the version. If you register it again, nothing changes."

  # The deployments, and the refusals, `history` lists before the one in force.
  @history_listed 20

  @impl Ehosctl.Command
  def name, do: :apps

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :applications

  @impl Ehosctl.Command
  def summary, do: "List your applications, and register and review versions."

  @impl Ehosctl.Command
  def runs_bare?, do: true

  @impl Ehosctl.Command
  def spec do
    app = [value_name: "APPLICATION", required: true, help: "The name of the application."]

    version = [
      value_name: "VERSION",
      required: true,
      help:
        "The digest of the version, or its start as the console shows it: sha256: and 12 " <>
          "digits."
    ]

    env = [
      long: "--env",
      value_name: "ENVIRONMENT",
      required: true,
      help: "The name of the environment."
    ]

    [
      about:
        "List the applications that you can use, where they are, and what you can do there. " <>
          "Register and review their versions, and manage sign-in agreements.",
      flags: Output.json_flag(),
      subcommands: [
        register: [
          name: "register",
          about:
            "Register an application manifest as a version. The version is in force in no " <>
              "environment yet.",
          args: [
            manifest: [
              value_name: "FILE",
              required: true,
              help:
                "The JSON file of the application manifest, as it was generated, or the " <>
                  "ehos.yaml of a utility service, whose manifest ehosctl writes. A file " <>
                  "named .yaml or .yml is an ehos.yaml. Give - for stdin, for a manifest."
            ]
          ],
          flags: Output.json_flag()
        ],
        show: [
          name: "show",
          about:
            "Show the versions of an application, and the version in force in each " <>
              "environment with the state of its deployment.",
          args: [application: app],
          flags: Output.json_flag()
        ],
        history: [
          name: "history",
          about:
            "Show the deployments of an application in an environment: the one in force, and " <>
              "each one before it, with how it ended and what came after it.",
          args: [application: app],
          options: [env: env],
          flags: Output.json_flag()
        ],
        review: [
          name: "review",
          about:
            "Show what a version changes, compared with the version in force in an " <>
              "environment. A deployment of the version puts these changes in force.",
          args: [application: app, version: version],
          options: [env: env],
          flags: Output.json_flag()
        ],
        "sign-in": Agreements.sign_in_spec()
      ]
    ]
  end

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], _parsed, opts) do
    {name, _} = installation = Keyword.fetch!(opts, :installation)

    with {:ok, applications} <- Api.applications(installation, opts) do
      {:ok, %{text: text(applications, name), json: %{applications: applications}}}
    end
  end

  def call([:register], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)

    with {:ok, manifest} <- manifest(parsed.args.manifest, opts) do
      installation
      |> Api.answer(
        :post,
        "/api/v1/applications/manifests",
        {:raw, "application/json", manifest},
        opts
      )
      |> registered(installation)
    end
  end

  def call([:"sign-in", action], parsed, opts), do: Agreements.sign_in(action, parsed, opts)

  def call(command, parsed, opts) do
    # A name that would leave its place in the path (`.`, `..`), or names nothing, is refused
    # before anything is sent: a proxy that resolves dot segments would send it elsewhere.
    case Enum.find(Map.values(parsed.args), &Api.is_nameless(&1)) do
      nil ->
        run(command, parsed, opts)

      word ->
        {:error, :invalid,
         "#{Refusal.shown(word)} is not the name of an application or a version."}
    end
  end

  defp run([:show], parsed, opts) do
    app = parsed.args.application

    with {:ok, versions} <- versions(app, opts) do
      states = states(app, versions["environments"], opts)

      versions =
        Map.update!(versions, "environments", fn envs ->
          Enum.map(envs, &Map.merge(&1, Map.fetch!(states, &1["name"])))
        end)

      if not parsed.flags.json, do: warn_unknown(versions["environments"])
      {:ok, %{text: shown(versions), json: versions}}
    end
  end

  defp run([:history], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    %{application: app} = parsed.args

    case Deployments.history(installation, app, parsed.options.env, opts, @history_listed) do
      {:ok, history} -> {:ok, %{text: DeploymentHistory.text(history), json: history}}
      {:lacking, why} -> {:error, :failed, why}
      error -> error
    end
  end

  defp run([:review], parsed, opts) do
    %{application: app, version: version} = parsed.args

    with {:ok, digest} <- digest(app, version, opts),
         {:ok, review} <- review(app, digest, parsed.options.env, opts) do
      {:ok, %{text: reviewed(review), json: %{review: review}}}
    end
  end

  ## Registering

  # A utility service's `ehos.yaml` has no generator to write its manifest: ehosctl writes it, as
  # the console's upload does (eh-os D-175). It is told by its name, so a manifest is never read
  # as YAML, and a refusal speaks of the file the person meant.
  defp manifest(file, opts) do
    if String.downcase(Path.extname(file)) in ~w(.yaml .yml),
      do: service_manifest(file, opts),
      else: ManifestFile.read(file, opts)
  end

  defp service_manifest(file, opts) do
    read = Keyword.merge(opts, what: "ehos.yaml", file_bytes: ServiceYaml.max_bytes())

    with {:ok, ehos_yaml} <- ManifestFile.read(file, read),
         do: ehos_yaml |> ServiceYaml.read() |> written_from(file)
  end

  defp written_from({:ok, service}, _file), do: {:ok, service.manifest}

  defp written_from({:error, reasons}, file),
    do:
      {:error, :invalid,
       "ehosctl refuses #{ManifestFile.where(file)}:\n" <>
         ServiceYaml.listed(reasons) <> "\nehosctl sent nothing."}

  # 201 for a version EHOS made, 200 for one it had: each with the outcome that says so.
  defp registered({:ok, %{status: status, body: body}}, installation) when status in [200, 201] do
    if submitted?(body, status) do
      body = Map.take(body, ~w(application version digest outcome))
      {:ok, %{text: registered_text(body, installation), json: body}}
    else
      {:error, kind, message} = Api.unexpected(installation)

      {:error, kind,
       message
       |> Failure.added(" EHOS answered #{status}, so it kept the version.")
       |> Failure.with_to_do("To see it, run:", [
         Config.command("ehosctl apps show APPLICATION", installation)
       ])}
    end
  end

  defp registered({:ok, %{status: 422} = answer}, installation),
    do: ManifestFile.refused(answer, installation)

  # A gateway's 5xx without EHOS's code may have come after the version was kept.
  defp registered({:ok, %{status: status} = answer}, installation) when status >= 500 do
    refused = Api.refusal(answer, installation)
    if Api.coded?(answer.body), do: refused, else: Refusal.added(refused, @again)
  end

  defp registered({:ok, answer}, installation), do: Api.refusal(answer, installation)

  # The same manifest registered again changes nothing, so it is safe to send again.
  defp registered({:error, kind, message, :sent}, _installation),
    do: {:error, kind, Failure.added(message, @again)}

  defp registered(error, _installation), do: error

  # A version made is in force nowhere until a deployment puts it there; reviewing it, in the
  # environment the person names, says what that would change.
  defp registered_text(%{"outcome" => "created"} = body, installation) do
    app = Refusal.shown(body["application"])
    digest = Refusal.shown(body["digest"])

    Output.lines([
      Output.outcome(
        :done,
        "Registered a version of #{app}. It is in force in no environment yet."
      ),
      Output.values([{"Version", digest}]),
      "",
      # EHOS names the application: quoted as one word, so a pasted command runs nothing else.
      Output.next([
        Config.command(
          "ehosctl apps review #{Shell.word(body["application"])} #{digest} --env ENVIRONMENT",
          installation
        )
      ])
    ])
  end

  defp registered_text(body, _installation),
    do:
      Output.lines([
        Output.outcome(
          :unchanged,
          "#{Refusal.shown(body["application"])} already has this version. Nothing changed."
        ),
        Output.values([{"Version", Refusal.shown(body["digest"])}])
      ])

  defp submitted?(%{} = body, status),
    do:
      Enum.all?(~w(application version), &is_binary(body[&1])) and digest?(body["digest"]) and
        {status, body["outcome"]} in [{201, "created"}, {200, "known"}]

  defp submitted?(_body, _status), do: false

  ## Versions

  defp versions(app, opts) do
    installation = Keyword.fetch!(opts, :installation)
    path = "/api/v1/applications/" <> Api.segment(app) <> "/versions"

    with {:ok, body} <- Api.read(installation, path, opts) do
      if versions?(body, app),
        do: {:ok, only_versions(body)},
        else: Api.unexpected(installation)
    end
  end

  # A whole digest is sent as it is, in the path too, where its colon may stand; the start of one
  # is looked up among the versions.
  defp digest(app, version, opts) do
    # Digits alone are a digest's without its algorithm, the only one EHOS uses.
    given = version
    version = if version =~ ~r/\A[0-9a-f]+\z/, do: "sha256:" <> version, else: version

    cond do
      Regex.match?(@digest, version) ->
        {:ok, version}

      Regex.match?(~r/\Asha256:[0-9a-f]{#{@shortest},63}\z/, version) ->
        start = version

        with {:ok, %{"versions" => versions}} <- versions(app, opts) do
          versions
          |> Enum.map(& &1["digest"])
          |> Enum.filter(&String.starts_with?(&1, start))
          |> one(app, start)
        end

      true ->
        {:error, :invalid,
         "#{Refusal.shown(given)} is not a version. Give its digest, sha256: and 64 digits, " <>
           "or at least its first #{@shortest} digits."}
    end
  end

  defp one([digest], _app, _start), do: {:ok, digest}

  defp one([], app, start),
    do:
      {:error, :failed,
       "#{Refusal.shown(app)} has no version whose digest starts with " <>
         "#{Refusal.shown(start)}."}

  defp one(several, app, start),
    do:
      {:error, :invalid,
       "#{length(several)} versions of #{Refusal.shown(app)} start with " <>
         "#{Refusal.shown(start)}. Give more of the digest."}

  # The versions of the application asked for, and no other.
  defp versions?(%{"application" => app, "versions" => versions, "environments" => envs}, app)
       when is_list(versions) and is_list(envs),
       do: Enum.all?(versions, &version?/1) and Enum.all?(envs, &environment?/1)

  defp versions?(_body, _app), do: false

  defp version?(%{"digest" => digest, "roles" => roles} = version) when is_list(roles),
    do:
      digest?(digest) and nil_or_digest?(version["authority_digest"]) and
        nil_or_text?(version["submitted_at"]) and Enum.all?(roles, &Review.role?/1) and
        hosts?(Map.get(version, "egress", []))

  defp version?(_version), do: false

  # eh-os D-135: each `host:port`; absent from an EHOS that predates `needs.egress`, and then none.
  defp hosts?(hosts), do: is_list(hosts) and Enum.all?(hosts, &is_binary/1)

  defp environment?(%{"name" => name} = env) when is_binary(name),
    do: nil_or_digest?(env["in_force"])

  defp environment?(_env), do: false

  defp digest?(digest), do: is_binary(digest) and Regex.match?(@digest, digest)
  defp nil_or_digest?(digest), do: is_nil(digest) or digest?(digest)

  defp only_versions(body) do
    %{
      "application" => body["application"],
      "versions" => Enum.map(body["versions"], &only_version/1),
      "environments" => Enum.map(body["environments"], &Map.take(&1, ~w(name in_force)))
    }
  end

  defp only_version(version) do
    version
    |> Map.take(~w(digest authority_digest submitted_at))
    |> Map.put("roles", Enum.map(version["roles"], &Review.role/1))
    |> Map.put("egress", Map.get(version, "egress", []))
  end

  ## Deployment states

  # Each environment's `state`: `failed` when the newest deployment there, decided after the one
  # in force, failed (`failed` holds it); else the state of the deployment in force, or `none`.
  # With that deployment and the addresses it is served at. An environment whose deployments
  # cannot be read is `unknown`, with `why`, and the others are still shown; once the
  # installation's EHOS is found to have no route for them, or the credential is no longer
  # accepted, no other environment is asked. A refusal may be of one environment alone.
  defp states(app, envs, opts) do
    installation = Keyword.fetch!(opts, :installation)

    envs
    |> Enum.reduce({%{}, nil}, fn %{"name" => env}, {states, stopped} ->
      read = stopped || Deployments.history(installation, app, env, opts)

      case read do
        {:ok, history} -> {Map.put(states, env, known(history)), nil}
        {:lacking, why} -> {Map.put(states, env, unknown(why)), read}
        {:error, :not_signed_in, why} -> {Map.put(states, env, unknown(why)), read}
        {:error, :not_signed_in, why, _refusal} -> {Map.put(states, env, unknown(why)), read}
        {:error, _kind, why} -> {Map.put(states, env, unknown(why)), nil}
        {:error, _kind, why, _refusal} -> {Map.put(states, env, unknown(why)), nil}
      end
    end)
    |> elem(0)
  end

  defp known(history) do
    in_force = history["in_force"]
    failed = Deployments.failed_after(history)

    state =
      cond do
        failed -> "failed"
        in_force -> in_force["state"]
        true -> "none"
      end

    %{
      "state" => state,
      "deployment" => in_force,
      "failed" => failed,
      "addresses" => history["addresses"],
      "why" => nil
    }
  end

  defp unknown(why),
    do: %{
      "state" => "unknown",
      "deployment" => nil,
      "failed" => nil,
      "addresses" => nil,
      "why" => why
    }

  defp state(%{"state" => "failed", "failed" => %{"failure" => failure}})
       when is_binary(failure) do
    failure =
      if String.length(failure) > @failure_shown,
        do: String.slice(failure, 0, @failure_shown - 1) <> "…",
        else: failure

    "failed: " <> Refusal.shown(failure)
  end

  defp state(%{"state" => "none"}), do: Output.none()
  defp state(%{"state" => state}), do: Refusal.shown(state)

  # Where each deployment in force came from, for the environments where EHOS names it.
  defp sources(envs) do
    envs
    |> Enum.flat_map(fn env ->
      case Source.line(env["deployment"]["source"]) do
        nil -> []
        line -> ["  #{Refusal.shown(env["name"])}: #{line}"]
      end
    end)
    |> case do
      [] -> []
      lines -> ["Where the deployment in force came from:" | lines]
    end
  end

  # Each reason a state is unknown, once, with the environments it is unknown in, as a warning.
  defp warn_unknown(envs) do
    envs
    |> Enum.filter(& &1["why"])
    |> Enum.chunk_by(& &1["why"])
    |> Enum.each(fn [%{"why" => why} | _] = same ->
      names = Enum.map_join(same, ", ", &Refusal.shown(&1["name"]))
      # The reason can be a failure with what to do in it, which a warning says as text.
      Output.warn("The state of the deployment is unknown in #{names}.", Failure.sentence(why))
    end)
  end

  defp shown(%{"application" => app, "versions" => versions, "environments" => envs}) do
    Enum.join(
      [Refusal.shown(app), "", in_force(app, envs)] ++
        sources(envs) ++ ["", "Versions, newest first:", listed(versions)],
      "\n"
    )
  end

  defp in_force(app, []), do: "You cannot review #{Refusal.shown(app)} in any environment."

  defp in_force(_app, envs) do
    envs
    |> Enum.map(fn env ->
      %{
        "ENVIRONMENT" => Refusal.shown(env["name"]),
        "IN FORCE" => if(env["in_force"], do: short(env["in_force"]), else: Output.none()),
        "STATE" => state(env)
      }
    end)
    |> Output.table(["ENVIRONMENT", "IN FORCE", "STATE"])
  end

  defp listed([]),
    do:
      "No versions. A version shows here when a person or a pipeline registers or deploys an " <>
        "application manifest."

  # The hosts outside the installation each version reaches (eh-os D-135), in a column of their
  # own once a version names one.
  defp listed(versions) do
    columns =
      if Enum.any?(versions, &(&1["egress"] != [])),
        do: ["VERSION", "SUBMITTED", "ROLES", "HOSTS OUTSIDE"],
        else: ["VERSION", "SUBMITTED", "ROLES"]

    versions
    |> Enum.map(fn version ->
      Map.take(
        %{
          "VERSION" => short(version["digest"]),
          "SUBMITTED" => Output.date(version["submitted_at"]),
          "ROLES" => Enum.map_join(version["roles"], ", ", &listed_role/1),
          "HOSTS OUTSIDE" => listed_hosts(version["egress"])
        },
        columns
      )
    end)
    |> Output.table(columns)
  end

  defp listed_hosts([]), do: Output.none()
  defp listed_hosts(hosts), do: Enum.map_join(hosts, ", ", &Refusal.shown/1)

  # eh-os D-112: a role says which roles its holders may grant, as the console does beside it.
  defp listed_role(%{"name" => name, "may_grant" => [_ | _] = granted}),
    do: "#{Refusal.shown(name)} (may grant #{Enum.map_join(granted, ", ", &Refusal.shown/1)})"

  defp listed_role(role), do: Refusal.shown(role["name"])

  ## Reviewing

  defp review(app, digest, env, opts) do
    installation = Keyword.fetch!(opts, :installation)

    path =
      "/api/v1/applications/" <>
        Api.segment(app) <>
        "/versions/" <> digest <> "/review?" <> URI.encode_query(environment: env)

    case Api.read(installation, path, opts) do
      # The review of the version and the environment asked for, and no other.
      {:ok,
       %{
         "review" =>
           %{"application" => ^app, "version" => ^digest, "environment" => ^env} = review
       }} ->
        if review?(review), do: {:ok, only_review(review)}, else: Api.unexpected(installation)

      {:ok, _body} ->
        Api.unexpected(installation)

      error ->
        error
    end
  end

  defp review?(review) do
    Enum.all?(~w(application environment version), &is_binary(review[&1])) and
      nil_or_digest?(review["in_force"]) and review["authority"] in ["changed", "unchanged"] and
      Review.changes?(review)
  end

  defp only_review(review) do
    review
    |> Map.take(~w(application environment version in_force authority))
    |> Map.merge(Review.kept(review))
  end

  defp reviewed(review) do
    where = "#{Refusal.shown(review["application"])} in #{Refusal.shown(review["environment"])}"
    version = short(review["version"])

    head =
      case review["in_force"] do
        nil ->
          "What version #{version} of #{where} changes, compared with nothing in force:"

        in_force ->
          "What version #{version} of #{where} changes, compared with #{short(in_force)} in " <>
            "force:"
      end

    case Review.lines(review) do
      [] ->
        head <>
          "\n  It changes the authority of no one: it grants what the version in force grants."

      lines ->
        Enum.join([head | lines], "\n")
    end
  end

  defp short("sha256:" <> hex), do: Refusal.shown("sha256:" <> String.slice(hex, 0, @shortest))
  defp short(other), do: Refusal.shown(other)

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  ## Listing the applications one may use

  defp text([], name),
    do:
      "No applications in #{name}. An application shows here when you have a role binding to " <>
        "one of its roles."

  defp text(applications, _name), do: Enum.map_join(applications, "\n\n", &entry/1)

  defp entry(entry) do
    heading =
      "#{Refusal.shown(entry["application"])} in #{Refusal.shown(entry["environment"])}, " <>
        "at #{entry["address"]}\n  roles: " <>
        Enum.map_join(entry["roles"], ", ", &Refusal.shown/1)

    case entry["capabilities"] do
      [] ->
        heading <>
          "\n  grants nothing: the application no longer has the role, or no version is in " <>
          "force there"

      capabilities ->
        width = capabilities |> Enum.map(&String.length(Refusal.shown(&1["name"]))) |> Enum.max()

        lines = Enum.map(capabilities, &capability_line(&1, width))
        Enum.join([heading | lines], "\n")
    end
  end

  defp capability_line(capability, width) do
    name = String.pad_trailing(Refusal.shown(capability["name"]), width)
    label = if is_binary(capability["label"]), do: Refusal.shown(capability["label"])

    label =
      if Api.known_kind?(capability["kind"]),
        do: label,
        else: "#{label} (needs a later ehosctl)"

    String.trim_trailing(
      "  #{String.pad_trailing(Refusal.shown(capability["kind"]), 7)}  #{name}  #{label}"
    )
  end
end
