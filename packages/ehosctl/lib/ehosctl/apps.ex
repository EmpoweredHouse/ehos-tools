defmodule Ehosctl.Apps do
  @moduledoc """
  `ehosctl apps`: the applications the person may use, each in an environment where they hold a
  role, with its address and what their roles grant there (`Ehosctl.Api.applications/2`). These
  are what `ehosctl credential` and `ehosctl call` reach.

  `ehosctl apps register | show | review | activate`: an application's manifest kept as a version,
  its versions and what is in force in each environment, what activating one would change, and its
  activation, through EHOS's API (eh-os
  [`docs/versions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/versions-api.md),
  D-32, D-52), as the console's Applications and application pages do. Each needs
  `ehos.application.register`: for the application, or at the whole platform to register a new
  one, and in the environment to review or activate there. EHOS decides and records each call, and
  its refusal is printed in its words.

  A version is named by its digest, or by the start of it the console shows (`sha256:` and 12
  digits), which the application's versions resolve. `activate` reviews first, prints what it
  changes, and activates only if the version in force is still the one the review showed.

  `ehosctl apps sign-in list | agree | withdraw`: other applications' pages getting credentials
  for an application in an environment, as its environment tab agrees (`Ehosctl.Agreements`).
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Agreements
  alias Ehosctl.Api
  alias Ehosctl.ManifestFile
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  # The start of a digest the console shows, and the least `ehosctl` resolves.
  @shortest 12

  @again " It may have been kept: registering it again changes nothing."

  @diff_lists ~w(capabilities_added capabilities_removed roles_added roles_removed)
  @diff_maps ~w(roles_grown roles_shrunk)

  @impl Ehosctl.Command
  def name, do: :apps

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def runs_bare?, do: true

  @impl Ehosctl.Command
  def spec do
    app = [value_name: "APPLICATION", required: true, help: "The application, by its name."]

    version = [
      value_name: "VERSION",
      required: true,
      help: "The version's digest, or its start as the console shows it: sha256: and 12 digits."
    ]

    env = [
      long: "--env",
      value_name: "ENVIRONMENT",
      required: true,
      help: "The environment, by its name."
    ]

    [
      about:
        "List the applications you may use, where they are, and what you may do there; " <>
          "register, review and activate their versions; agree to other applications' pages " <>
          "signing in to them.",
      flags: Output.json_flag(),
      subcommands: [
        register: [
          name: "register",
          about: "Keep an application's manifest as a version, in force nowhere yet.",
          args: [
            manifest: [
              value_name: "FILE",
              required: true,
              help: "The application manifest, its JSON file as it was generated; - for stdin."
            ]
          ],
          flags: Output.json_flag()
        ],
        show: [
          name: "show",
          about: "Show an application's versions, and the version in force in each environment.",
          args: [application: app],
          flags: Output.json_flag()
        ],
        review: [
          name: "review",
          about: "Show what activating a version in an environment would change.",
          args: [application: app, version: version],
          options: [env: env],
          flags: Output.json_flag()
        ],
        activate: [
          name: "activate",
          about:
            "Put a version in force in an environment, printing what it changes, if the " <>
              "version in force is still the one the review shows.",
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

    with {:ok, manifest} <- ManifestFile.read(parsed.args.manifest, opts) do
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
    case Enum.find(Map.values(parsed.args), &(&1 in ["", ".", ".."])) do
      nil -> run(command, parsed, opts)
      word -> {:error, :invalid, "#{Refusal.shown(word)} names no application or version."}
    end
  end

  defp run([:show], parsed, opts) do
    with {:ok, versions} <- versions(parsed.args.application, opts) do
      {:ok, %{text: shown(versions), json: versions}}
    end
  end

  defp run([:review], parsed, opts) do
    %{application: app, version: version} = parsed.args

    with {:ok, digest} <- digest(app, version, opts),
         {:ok, review} <- review(app, digest, parsed.options.env, opts) do
      {:ok, %{text: reviewed(review), json: %{review: review}}}
    end
  end

  defp run([:activate], parsed, opts) do
    %{application: app, version: version} = parsed.args

    with {:ok, digest} <- digest(app, version, opts),
         {:ok, review} <- review(app, digest, parsed.options.env, opts),
         {:ok, %{text: text, json: json}} <- activate(app, review, opts) do
      {:ok, %{text: reviewed(review) <> "\n\n" <> text, json: Map.put(json, :review, review)}}
    end
  end

  ## Registering

  # 201 for a version EHOS made, 200 for one it had: each with the outcome that says so.
  defp registered({:ok, %{status: status, body: body}}, installation) when status in [200, 201] do
    if submitted?(body, status) do
      body = Map.take(body, ~w(application version digest outcome))
      {:ok, %{text: registered_text(body), json: body}}
    else
      {:error, kind, message} = Api.unexpected(installation)

      {:error, kind,
       message <>
         " It answered #{status}, so the version is kept: run " <>
         "`ehosctl apps show <application>` to see."}
    end
  end

  defp registered({:ok, %{status: 422} = answer}, installation),
    do: ManifestFile.refused(answer, installation)

  # A gateway's 5xx without EHOS's code may have come after the version was kept.
  defp registered({:ok, %{status: status} = answer}, installation) when status >= 500 do
    {:error, kind, message} = Api.refusal(answer, installation)

    if Api.coded?(answer.body),
      do: {:error, kind, message},
      else: {:error, kind, message <> @again}
  end

  defp registered({:ok, answer}, installation), do: Api.refusal(answer, installation)

  # The same manifest registered again changes nothing, so it is safe to send again.
  defp registered({:error, kind, message, :sent}, _installation),
    do: {:error, kind, message <> @again}

  defp registered(error, _installation), do: error

  defp registered_text(%{"outcome" => "created"} = body),
    do:
      "Registered #{Refusal.shown(body["digest"])} of #{Refusal.shown(body["application"])}. " <>
        "It is in force nowhere until it is activated: `ehosctl apps review` shows what it " <>
        "would change."

  defp registered_text(body),
    do:
      "#{Refusal.shown(body["application"])} already has #{Refusal.shown(body["digest"])}; " <>
        "nothing changed."

  defp submitted?(%{} = body, status),
    do:
      Enum.all?(~w(application version), &is_binary(body[&1])) and digest?(body["digest"]) and
        {status, body["outcome"]} in [{201, "created"}, {200, "known"}]

  defp submitted?(_body, _status), do: false

  ## Versions

  defp versions(app, opts) do
    installation = Keyword.fetch!(opts, :installation)
    path = "/api/v1/applications/" <> segment(app) <> "/versions"

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
         "#{Refusal.shown(given)} is not a version: give its digest, sha256: and 64 digits, " <>
           "or at least its first #{@shortest}."}
    end
  end

  defp one([digest], _app, _start), do: {:ok, digest}

  defp one([], app, start),
    do:
      {:error, :failed,
       "#{Refusal.shown(app)} has no version whose digest starts #{Refusal.shown(start)}."}

  defp one(several, app, start),
    do:
      {:error, :invalid,
       "#{length(several)} versions of #{Refusal.shown(app)} start #{Refusal.shown(start)}: " <>
         "give more of the digest."}

  # The versions of the application asked for, and no other.
  defp versions?(%{"application" => app, "versions" => versions, "environments" => envs}, app)
       when is_list(versions) and is_list(envs),
       do: Enum.all?(versions, &version?/1) and Enum.all?(envs, &environment?/1)

  defp versions?(_body, _app), do: false

  defp version?(%{"digest" => digest, "roles" => roles} = version) when is_list(roles),
    do:
      digest?(digest) and nil_or_digest?(version["authority_digest"]) and
        nil_or_text?(version["submitted_at"]) and Enum.all?(roles, &role?/1)

  defp version?(_version), do: false

  defp role?(%{"name" => name, "capabilities" => capabilities} = role)
       when is_binary(name) and is_list(capabilities),
       do: nil_or_text?(role["label"]) and Enum.all?(capabilities, &capability?/1)

  defp role?(_role), do: false

  defp capability?(%{"name" => name} = capability) when is_binary(name),
    do: description?(capability)

  defp capability?(_capability), do: false

  # What a capability says beside its name: its label, its kind, and the principals it serves.
  defp description?(%{} = described),
    do:
      nil_or_text?(described["label"]) and nil_or_text?(described["kind"]) and
        (is_nil(described["principals"]) or names?(described["principals"]))

  defp description?(_described), do: false

  defp only_role(role),
    do: %{
      "name" => role["name"],
      "label" => role["label"],
      "capabilities" =>
        Enum.map(role["capabilities"], &Map.take(&1, ~w(name label kind principals)))
    }

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
    |> Map.put("roles", Enum.map(version["roles"], &only_role/1))
  end

  defp shown(%{"application" => app, "versions" => versions, "environments" => envs}) do
    Enum.join(
      [
        Refusal.shown(app),
        "",
        in_force(app, envs),
        "",
        "Versions, newest first:",
        listed(versions)
      ],
      "\n"
    )
  end

  defp in_force(app, []), do: "You may activate #{Refusal.shown(app)} in no environment."

  defp in_force(_app, envs) do
    envs
    |> Enum.map(fn env ->
      %{
        "ENVIRONMENT" => Refusal.shown(env["name"]),
        "IN FORCE" => if(env["in_force"], do: short(env["in_force"]), else: "none")
      }
    end)
    |> Output.table(["ENVIRONMENT", "IN FORCE"])
  end

  defp listed([]), do: "No versions."

  defp listed(versions) do
    versions
    |> Enum.map(fn version ->
      %{
        "VERSION" => short(version["digest"]),
        "SUBMITTED" => Refusal.shown(version["submitted_at"] || ""),
        "ROLES" => Enum.map_join(version["roles"], ", ", &Refusal.shown(&1["name"]))
      }
    end)
    |> Output.table(["VERSION", "SUBMITTED", "ROLES"])
  end

  ## Reviewing and activating

  defp review(app, digest, env, opts) do
    installation = Keyword.fetch!(opts, :installation)

    path =
      "/api/v1/applications/" <>
        segment(app) <>
        "/versions/" <> digest <> "/review?" <> URI.encode_query(environment: env)

    case Api.read(installation, path, opts) do
      # The review of the version and the environment asked for, and no other: its version is
      # where the activation is sent.
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

  # What the review showed in force is what the activation replaces, so a version activated
  # meanwhile by someone else is refused, `changed`, rather than replaced unseen.
  defp activate(app, review, opts) do
    path =
      "/api/v1/applications/" <>
        segment(app) <> "/versions/" <> review["version"] <> "/activate"

    body = %{environment: review["environment"], replacing: review["in_force"]}

    Api.write(
      opts,
      {:post, path, body},
      [
        status: 200,
        key: "in_force",
        valid?: &activated?(&1, review),
        only: &Map.take(&1, ~w(application environment version activated_at)),
        look: "`ehosctl apps show #{Refusal.shown(app)}`"
      ],
      fn in_force ->
        "#{short(in_force["version"])} is in force in #{Refusal.shown(in_force["environment"])}."
      end
    )
  end

  defp activated?(
         %{"application" => app, "version" => version, "environment" => env} = in_force,
         review
       ),
       do:
         app == review["application"] and version == review["version"] and
           env == review["environment"] and nil_or_text?(in_force["activated_at"])

  defp activated?(_in_force, _review), do: false

  defp review?(%{"diff" => %{} = diff, "described" => %{} = described} = review) do
    Enum.all?(~w(application environment version), &is_binary(review[&1])) and
      nil_or_digest?(review["in_force"]) and review["authority"] in ["changed", "unchanged"] and
      Enum.all?(@diff_lists, &names?(diff[&1])) and Enum.all?(@diff_maps, &grown?(diff[&1])) and
      all?(described["roles_added"], &role?/1) and
      all?(described["redescribed"], &redescribed?/1) and
      all?(described["grants_changed"], &redescribed?/1)
  end

  defp review?(_review), do: false

  defp names?(names), do: is_list(names) and Enum.all?(names, &is_binary/1)

  defp all?(list, valid?), do: is_list(list) and Enum.all?(list, valid?)

  # A capability or a role described otherwise under the same name: as it was, and as it is.
  defp redescribed?(%{"name" => name, "from" => from, "to" => to}) when is_binary(name),
    do: description?(from) and description?(to)

  defp redescribed?(_change), do: false

  defp only_redescribed(change),
    do: %{
      "name" => change["name"],
      "from" => Map.take(change["from"], ~w(label kind principals)),
      "to" => Map.take(change["to"], ~w(label kind principals))
    }

  defp grown?(roles),
    do:
      is_map(roles) and
        Enum.all?(roles, fn {role, names} -> is_binary(role) and names?(names) end)

  defp only_review(review) do
    described = review["described"]

    review
    |> Map.take(~w(application environment version in_force authority))
    |> Map.put("diff", Map.take(review["diff"], @diff_lists ++ @diff_maps))
    |> Map.put("described", %{
      "roles_added" => Enum.map(described["roles_added"], &only_role/1),
      "redescribed" => Enum.map(described["redescribed"], &only_redescribed/1),
      "grants_changed" => Enum.map(described["grants_changed"], &only_redescribed/1)
    })
  end

  defp reviewed(review) do
    where = "#{Refusal.shown(review["application"])} in #{Refusal.shown(review["environment"])}"
    version = short(review["version"])

    head =
      case review["in_force"] do
        nil -> "Activating #{version} of #{where}, where nothing is in force:"
        in_force -> "Activating #{version} of #{where}, replacing #{short(in_force)}:"
      end

    case {changes(review), review["authority"]} do
      {[], "unchanged"} ->
        head <> "\n  It changes no one's authority: what it grants is what is in force."

      # The authority form holds more than this review names: what a capability runs, and what of
      # the application's needs names a capability.
      {[], _changed} ->
        head <>
          "\n  No capability or role is added, removed or relabelled, but its authority " <>
          "changes: what a capability runs, or what the application needs, differs."

      {lines, _authority} ->
        Enum.join([head | lines], "\n")
    end
  end

  defp changes(%{"diff" => diff, "described" => described}) do
    Enum.reject(
      [
        list("capabilities added", diff["capabilities_added"]),
        list("capabilities removed", diff["capabilities_removed"]),
        list("roles added", diff["roles_added"]),
        list("roles removed", diff["roles_removed"]),
        grown("roles that grow, giving everyone bound to them more", diff["roles_grown"]),
        grown("roles that shrink", diff["roles_shrunk"]),
        list(
          "what a capability lets its holders do changed for",
          names(described["grants_changed"])
        ),
        list("descriptions changed for", names(described["redescribed"]))
      ],
      &is_nil/1
    )
  end

  defp list(_label, []), do: nil
  defp list(label, names), do: "  #{label}: " <> Enum.map_join(names, ", ", &Refusal.shown/1)

  defp grown(_label, roles) when map_size(roles) == 0, do: nil

  defp grown(label, roles) do
    "  #{label}: " <>
      Enum.map_join(Enum.sort(roles), "; ", fn {role, names} ->
        "#{Refusal.shown(role)} (#{Enum.map_join(names, ", ", &Refusal.shown/1)})"
      end)
  end

  defp names(changes), do: for(%{"name" => name} when is_binary(name) <- changes, do: name)

  defp short("sha256:" <> hex), do: Refusal.shown("sha256:" <> String.slice(hex, 0, @shortest))
  defp short(other), do: Refusal.shown(other)

  defp segment(name), do: URI.encode(name, &URI.char_unreserved?/1)

  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  ## Listing the applications one may use

  defp text([], name), do: "None of your roles in #{name} is bound in an application."

  defp text(applications, _name), do: Enum.map_join(applications, "\n\n", &entry/1)

  defp entry(entry) do
    heading =
      "#{Refusal.shown(entry["application"])} in #{Refusal.shown(entry["environment"])}, " <>
        "at #{entry["address"]}\n  roles: " <>
        Enum.map_join(entry["roles"], ", ", &Refusal.shown/1)

    case entry["capabilities"] do
      [] ->
        heading <> "\n  grants nothing: the role is gone, or no version is in force there"

      capabilities ->
        width = capabilities |> Enum.map(&String.length(Refusal.shown(&1["name"]))) |> Enum.max()

        lines =
          Enum.map(capabilities, fn capability ->
            name = String.pad_trailing(Refusal.shown(capability["name"]), width)
            label = if is_binary(capability["label"]), do: Refusal.shown(capability["label"])

            label =
              if Api.known_kind?(capability["kind"]),
                do: label,
                else: "#{label} (needs a later ehosctl)"

            String.trim_trailing(
              "  #{String.pad_trailing(Refusal.shown(capability["kind"]), 7)}  #{name}  #{label}"
            )
          end)

        Enum.join([heading | lines], "\n")
    end
  end
end
