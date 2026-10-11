defmodule Ehosctl.Deploy do
  @moduledoc """
  `ehosctl deploy <application> --env E --image <repository>@sha256:… --manifest <file>`: deploys
  an image, by digest, with its application manifest, to an environment, as the console's deploy
  page does (eh-os D-52, D-53,
  [`docs/manifest.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/manifest.md#deploying-with-one)).

  It sends `POST /api/v1/deployments?environment=E&image=…` with the manifest as its body, the bytes
  of the file as they are, since EHOS keeps and digests the manifest as it was sent. The manifest
  must be for `<application>`, or nothing is sent: the name on the command line is what the person
  meant to deploy, and a manifest of another application would deploy that one.

  It needs `ehos.application.deploy` in the environment, and `ehos.application.register` too when
  the manifest puts another authority in force. A refusal is printed in the deploy page's words.

  EHOS answers once the cluster has the deployment's objects, while it is `activating`; whether
  it became active is on the application's page in the console, since the API does not say yet.

  `ehosctl deploy <application> --env E --manifest <file> --preview` deploys nothing: it prints
  what the deployment would do, as the deploy page shows it before it is confirmed, from
  `POST /api/v1/deployments/preview?environment=E` with the same body (eh-os#373). That is the
  application, and whether EHOS knows it yet; both of the manifest's digests and the version in
  force; what its authority adds and takes away, as `ehosctl apps review` says it
  (`Ehosctl.Review`); whether it also needs `ehos.application.register`; each need's binding;
  what it changes in sign-in and in reading the company's people; and every reason it would be
  refused. It exits 0 when there is none, and 1, `:failed`, with the preview printed, when there
  is one. The preview takes no image, so `--image` is refused with `--preview`.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.ManifestFile
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.Review

  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  @impl Ehosctl.Command
  def name, do: :deploy

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Deploy an image, by digest, with its manifest, to an environment, or preview what " <>
          "deploying the manifest would do.",
      args: [
        application: [
          value_name: "APPLICATION",
          required: true,
          help: "The application, as its manifest names it."
        ]
      ],
      options: [
        env: [
          long: "--env",
          value_name: "ENVIRONMENT",
          required: true,
          help: "The environment to deploy to."
        ],
        image: [
          long: "--image",
          value_name: "IMAGE",
          help:
            "The image, by digest: <registry>/<repository>@sha256:<digest>. Needed to deploy; " <>
              "not taken with --preview."
        ],
        manifest: [
          long: "--manifest",
          value_name: "FILE",
          required: true,
          help: "The application manifest, its JSON file as it was generated; - for stdin."
        ]
      ],
      flags:
        [
          preview: [
            long: "--preview",
            help:
              "Print what the deployment would do, and every reason it would be refused; deploy nothing."
          ]
        ] ++ Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    application = parsed.args.application
    %{env: env, image: image, manifest: file} = parsed.options
    %{preview: preview?, json: json?} = parsed.flags

    with :ok <- image(image, preview?),
         {:ok, manifest} <- ManifestFile.read(file, opts),
         :ok <- for_application(manifest, file, application) do
      if preview?,
        do: preview(manifest, application, env, json?, opts),
        else: deploy(manifest, application, env, image, opts)
    end
  end

  # EHOS's preview reads the manifest alone: the route takes no image. An image given with
  # `--preview` would be checked by nothing, and a preview that passed would seem to say it was
  # (the deploy page checks it is pinned by digest before it previews). It is refused rather than
  # ignored, so that what a preview prints is all it checked.
  defp image(nil, false),
    do:
      {:error, :invalid,
       "Deploying needs --image, the image by digest: " <>
         "<registry>/<repository>@sha256:<digest>. --preview shows what the deployment would " <>
         "do without one."}

  defp image(_image, false), do: :ok
  defp image(nil, true), do: :ok

  defp image(_image, true),
    do:
      {:error, :invalid,
       "--preview takes no --image: EHOS previews the manifest alone, and checks the image " <>
         "when it is deployed. Leave --image out of the preview, and give it to deploy."}

  defp deploy(manifest, application, env, image, opts) do
    installation = Keyword.fetch!(opts, :installation)
    path = "/api/v1/deployments?" <> URI.encode_query(environment: env, image: image)

    installation
    |> Api.answer(:post, path, {:raw, "application/json", manifest}, opts)
    |> answered(installation, application, env)
  end

  defp for_application(manifest, file, application) do
    where = ManifestFile.where(file)

    case JSON.decode(manifest) do
      {:ok, %{"application" => ^application}} ->
        :ok

      {:ok, %{"application" => other}} when is_binary(other) ->
        {:error, :invalid,
         "#{where} is the manifest of #{Refusal.shown(other)}, not of " <>
           "#{Refusal.shown(application)}; nothing was sent."}

      {:ok, %{"application" => _other}} ->
        {:error, :invalid, "#{where} names its application other than as text."}

      {:ok, %{}} ->
        {:error, :invalid, "#{where} names no application, so it is not a manifest."}

      _other ->
        {:error, :invalid, "#{where} does not hold a JSON object, so it is not a manifest."}
    end
  end

  defp answered({:ok, %{status: 201, body: body}}, installation, application, env) do
    if is_map(body) and deployment?(body) do
      {:ok, %{text: deployed(body, application, env), json: body}}
    else
      {:error, kind, message} = Api.unexpected(installation)

      {:error, kind,
       message <>
         " It answered 201, so the deployment was decided: see #{Refusal.shown(application)}'s " <>
         "page in the console for #{Refusal.shown(env)}."}
    end
  end

  # A deployment decided and then failed or superseded: the refusal, and which deployment it was.
  defp answered(
         {:ok, %{status: status, body: %{"deployment" => id} = body} = answer},
         installation,
         _app,
         _env
       )
       when status in [409, 502] and is_binary(id) do
    {:error, kind, message} = Api.refusal(answer, installation)

    failure =
      if is_binary(body["failure"]), do: " Its failure: #{Refusal.shown(body["failure"])}."

    {:error, kind, "#{message} Deployment #{Refusal.shown(id)}.#{failure}"}
  end

  defp answered({:ok, %{status: 422} = answer}, installation, _application, _env),
    do: ManifestFile.refused(answer, installation)

  # A 5xx with no code of EHOS's own, such as a gateway's timeout, may have come after the
  # deployment was decided.
  defp answered({:ok, %{status: status} = answer}, installation, application, env)
       when status >= 500 do
    {:error, kind, message} = Api.refusal(answer, installation)

    if Api.coded?(answer.body),
      do: {:error, kind, message},
      else: {:error, kind, message <> maybe_deployed(application, env)}
  end

  defp answered({:ok, answer}, installation, _application, _env),
    do: Api.refusal(answer, installation)

  defp answered({:error, kind, message, :sent}, _installation, application, env),
    do: {:error, kind, message <> maybe_deployed(application, env)}

  defp answered(error, _installation, _application, _env), do: error

  defp maybe_deployed(application, env),
    do:
      " It may have been deployed: see #{Refusal.shown(application)}'s page in the console for " <>
        "#{Refusal.shown(env)} before deploying again."

  defp deployment?(body),
    do: Enum.all?(~w(deployment image digest authority_digest state), &is_binary(body[&1]))

  defp deployed(body, application, env) do
    Enum.join(
      [
        "Deployed #{Refusal.shown(application)} to #{Refusal.shown(env)}: deployment " <>
          "#{Refusal.shown(body["deployment"])} is #{Refusal.shown(body["state"])}.",
        "  image:            #{Refusal.shown(body["image"])}",
        "  manifest digest:  #{Refusal.shown(body["digest"])}",
        "  authority digest: #{Refusal.shown(body["authority_digest"])}",
        "Whether it became active is on the application's page in the console."
      ],
      "\n"
    )
  end

  ## Previewing

  defp preview(manifest, application, env, json?, opts) do
    installation = Keyword.fetch!(opts, :installation)
    path = "/api/v1/deployments/preview?" <> URI.encode_query(environment: env)

    answer = Api.answer(installation, :post, path, {:raw, "application/json", manifest}, opts)

    with {:ok, preview} <- previewed(answer, installation, application, env) do
      output = %{text: preview_text(preview), json: preview}

      # A preview with refusals is still printed whole, on stdout, as the deploy page shows it
      # with its reasons: the exit code says the deployment would not be taken.
      case preview["refusals"] do
        [] ->
          {:ok, output}

        _refusals ->
          Output.result(output, json?)
          Output.code(:failed)
      end
    end
  end

  # The preview of the application and the environment asked for, and no other.
  defp previewed({:ok, %{status: 200, body: body}}, installation, application, env) do
    if preview?(body, application, env),
      do: {:ok, kept(body)},
      else: Api.unexpected(installation)
  end

  defp previewed({:ok, %{status: 422} = answer}, installation, _application, _env),
    do: ManifestFile.refused(answer, installation)

  defp previewed({:ok, answer}, installation, _application, _env),
    do: Api.refusal(answer, installation)

  # A preview writes nothing, so one that went unanswered did nothing either.
  defp previewed({:error, kind, message, :sent}, _installation, _application, _env),
    do: {:error, kind, message}

  defp previewed(error, _installation, _application, _env), do: error

  defp preview?(
         %{"application" => application, "environment" => env} = preview,
         application,
         env
       ),
       do:
         is_boolean(preview["known"]) and digest?(preview["digest"]) and
           digest?(preview["authority_digest"]) and
           (is_nil(preview["in_force"]) or digest?(preview["in_force"])) and
           preview["authority"] in ["changed", "unchanged"] and Review.changes?(preview) and
           register?(preview["register"]) and all?(preview["needs"], &need?/1) and
           sign_in?(preview["sign_in"]) and people?(preview["people"]) and
           all?(preview["refusals"], &is_binary/1)

  defp preview?(_preview, _application, _env), do: false

  defp register?(%{"needed" => needed, "held" => held}),
    do: is_boolean(needed) and is_boolean(held)

  defp register?(_register), do: false

  defp need?(%{"need" => need, "engine" => engine} = asked)
       when is_binary(need) and is_binary(engine),
       do: nil_or_text?(asked["version"]) and binding?(asked)

  defp need?(_need), do: false

  # Bound to a resource, or refused with why: one of the two.
  defp binding?(%{"bound" => bound} = need),
    do: is_binary(bound) and not Map.has_key?(need, "refused")

  defp binding?(%{"refused" => why}), do: is_binary(why)
  defp binding?(_need), do: false

  defp sign_in?(nil), do: true

  defp sign_in?(%{"adds" => adds, "applications" => applications}) when is_boolean(adds),
    do: all?(applications, &signs_in?/1)

  defp sign_in?(_sign_in), do: false

  defp signs_in?(%{"name" => name, "new" => new, "agreed" => agreed}),
    do: is_binary(name) and is_boolean(new) and is_boolean(agreed)

  defp signs_in?(_application), do: false

  # One of the two forms eh-os sends, and only it: `--json` keeps the one key read.
  defp people?(nil), do: true
  defp people?(%{"removes" => true} = people), do: not Map.has_key?(people, "adds")

  defp people?(%{"adds" => adds} = people),
    do: is_boolean(adds) and not Map.has_key?(people, "removes")

  defp people?(_people), do: false

  defp digest?(digest), do: is_binary(digest) and Regex.match?(@digest, digest)

  defp all?(list, valid?), do: is_list(list) and Enum.all?(list, valid?)
  defp nil_or_text?(value), do: is_nil(value) or is_binary(value)

  # Kept to the fields read, so nothing else an answer holds reaches a script under `--json`.
  defp kept(preview) do
    sign_in =
      if preview["sign_in"],
        do: %{
          "adds" => preview["sign_in"]["adds"],
          "applications" =>
            Enum.map(preview["sign_in"]["applications"], &Map.take(&1, ~w(name new agreed)))
        }

    preview
    |> Map.take(
      ~w(application known environment digest authority_digest in_force authority refusals)
    )
    |> Map.merge(Review.kept(preview))
    |> Map.merge(%{
      "register" => Map.take(preview["register"], ~w(needed held)),
      "needs" => Enum.map(preview["needs"], &Map.take(&1, ~w(need engine version bound refused))),
      "sign_in" => sign_in,
      "people" => preview["people"]
    })
  end

  # The deploy page's words for each part of the preview (eh-os `EhosWeb.DeployLive`).
  defp preview_text(preview) do
    app = Refusal.shown(preview["application"])
    env = Refusal.shown(preview["environment"])

    [
      [
        "What deploying #{app} to #{env} would do; nothing was deployed.",
        "  manifest digest:  #{Refusal.shown(preview["digest"])}",
        "  authority digest: #{Refusal.shown(preview["authority_digest"])}",
        "  in force now:     #{Refusal.shown(preview["in_force"] || "none")}"
      ],
      not preview["known"] &&
        [
          "EHOS does not know #{app} yet: this deployment registers it, with this manifest as " <>
            "its first version."
        ],
      preview["register"] == %{"needed" => true, "held" => true} &&
        [
          "It puts another authority in force in #{env}, which also needs " <>
            "ehos.application.register there. You hold it."
        ],
      authority(preview, env),
      needs(preview["needs"]),
      sign_in(preview["sign_in"], app, env),
      people(preview["people"], app, env),
      refusals(preview["refusals"])
    ]
    |> Enum.filter(&is_list/1)
    |> Enum.map_join("\n\n", &Enum.join(&1, "\n"))
  end

  defp authority(preview, env) do
    case {Review.lines(preview), preview["in_force"]} do
      {[], _in_force} ->
        [
          "This manifest grants what the version in force grants, so deploying it changes no " <>
            "one's authority in #{env}."
        ]

      # With nothing in force, there is nothing for its authority to differ from.
      {_lines, nil} ->
        case Review.named(preview) do
          [] ->
            ["With nothing in force in #{env}, its authority names no capability and no role."]

          named ->
            ["What its authority adds, with nothing in force in #{env}:" | named]
        end

      {lines, _in_force} ->
        ["What its authority adds and takes away against the version in force:" | lines]
    end
  end

  defp needs([]), do: nil

  defp needs(needs) do
    rows =
      Enum.map(needs, fn need ->
        %{
          "NEEDS" => Refusal.shown(need["need"]),
          "ASKS FOR" => asks(need),
          "BOUND TO" => bound(need)
        }
      end)

    [Output.table(rows, ["NEEDS", "ASKS FOR", "BOUND TO"])]
  end

  defp bound(%{"bound" => bound}), do: Refusal.shown(bound)
  defp bound(%{"refused" => why}), do: "cannot be bound: " <> Refusal.shown(why)

  # A need may ask for no version: its engine alone is shown.
  defp asks(%{"engine" => engine, "version" => version}) when is_binary(version),
    do: "#{Refusal.shown(engine)} #{Refusal.shown(version)}"

  defp asks(%{"engine" => engine}), do: Refusal.shown(engine)

  defp sign_in(nil, _app, _env), do: nil

  defp sign_in(%{"adds" => adds, "applications" => applications}, app, env) do
    added =
      "This deployment signs people in to #{app} through EHOS: its workload becomes a client " <>
        "of sign-in in #{env}."

    case {adds, applications} do
      {false, []} -> nil
      {false, _applications} -> [calls(applications, env)]
      {true, []} -> [added]
      {true, _applications} -> [added, calls(applications, env)]
    end
  end

  # The applications its pages call, and whether each has agreed to credentials for it.
  defp calls(applications, env) do
    applications
    |> Enum.map(fn other ->
      name = Refusal.shown(other["name"])

      credentials =
        if other["agreed"],
          do: "agreed by its side",
          else: "none until someone who may deploy #{name} in #{env} agrees"

      %{
        "ITS PAGES CALL" => if(other["new"], do: name <> " (new)", else: name),
        "CREDENTIALS FOR IT" => credentials
      }
    end)
    |> Output.table(["ITS PAGES CALL", "CREDENTIALS FOR IT"])
  end

  defp people(nil, _app, _env), do: nil

  defp people(%{"removes" => true}, _app, env),
    do: [
      "This deployment stops reading the company's people: the deployment in force in #{env} " <>
        "asks to, and this one does not."
    ]

  defp people(%{"adds" => true}, app, env),
    do: [
      "This deployment asks to read the company's people: #{app} will be given a key to " <>
        "identify itself to EHOS in #{env}, and reads the people only once someone who manages " <>
        "people agrees there."
    ]

  defp people(%{"adds" => false}, _app, _env),
    do: [
      "It reads the company's people, as the deployment in force there does, once someone who " <>
        "manages people agrees."
    ]

  defp refusals([]),
    do: ["To deploy it, run the command again without --preview, naming the image with --image."]

  defp refusals([reason]),
    do: ["The deployment would be refused, for this reason:", "  - " <> Refusal.shown(reason)]

  defp refusals(reasons),
    do: [
      "The deployment would be refused, for these reasons:"
      | Enum.map(reasons, &("  - " <> Refusal.shown(&1)))
    ]
end
