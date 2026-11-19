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

  `--graph <file>`, given once for each graph document of the application, its domains', its
  contracts' and its process modules', sends it with the manifest, as its pipeline writes them
  with `mix eh_os_contract.graph --output-dir` (eh-os D-123, D-134, eh-os#785): the body is then
  `multipart/form-data`, the manifest's part first and a part `graph` for each document, each the
  bytes of its file, UTF-8. Before it signs in and sends the request, it says on stderr how many
  documents go with the manifest and how many bytes they are in all, unless under `--json`. EHOS
  takes at most 512 documents, 32 MiB in all and 1 MiB each, and past any of these they are
  refused here, in the words EHOS would answer, and nothing is sent.
  EHOS keeps what it reads of them for the landscape of applications (`ehosctl landscape`), and
  refuses the deployment, with each reason, when one is broken or claims another application's
  facts. Without `--graph` the body is the manifest alone, as before, which an EHOS older than
  eh-os#785 takes too; one that old reads a body with documents as a manifest, and refuses it,
  and one older than eh-os#884 refuses a contract's or a process module's document.

  `ehosctl deploy <application> --env E --build <id | commit>`, or `--build latest --ref <ref>`,
  deploys a build the application's CI registered (eh-os
  [D-146](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0146-a-build-is-a-record-of-its-own-registered-by-ci-with-the-commit-it-came-from-a-deployment-names-a-build-and-a-promotion-s-review-links-to-what-changed.md),
  [`docs/manifest.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/manifest.md#deploying-a-build)):
  `POST /api/v1/deployments?environment=E&application=A&build=…`, with no body, since the build
  holds its image, its manifest and its graph documents. A build is named by its id
  (`ehosctl builds list`), by a commit, or as `latest` of a ref given in full as GitHub's token
  names it (`refs/heads/main`); EHOS takes a commit and `latest` among the builds a pipeline
  registered, never one a person did, which is deployed by its id alone. `--repository owner/name`
  narrows a commit or `latest` to one repository, needed when builds of more than one match. What
  EHOS refuses beside a build, `--image`, `--manifest`, `--bundle`, `--graph`, `--commit`, a `--ref`
  with an id or a commit, is refused here, and so is `--preview`, since EHOS previews a manifest.
  The deployment is named as its build is, and is followed as any other is. An EHOS before
  builds refuses it for the image it lacks.

  `--create-env`, with `--build`, creates the ephemeral environment first when EHOS has none of
  that name, as the console's deploy page does
  ([D-156](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0156-a-person-chooses-which-build-runs-in-an-ephemeral-environment-and-the-template-previews-a-pull-request-only-when-its-repository-turns-previews-on.md)):
  it reads `GET /api/v1/environments/E`, and on EHOS's `not_found` sends
  `POST /api/v1/environments` for an ephemeral environment of the application, from `--template`
  or the installation's default environment template (`Ehosctl.Env.create_ephemeral/5`), without
  its role entries and people agreement with `--no-role-bindings` (eh-os D-161), then the
  deployment. Each is decided and recorded on its own. A pipeline's credential may not read an
  environment, so in a job `--create-env` is refused, with how to create the environment first.
  A refusal at the count names the environments that hold it (`Ehosctl.AtCount`) and deploys
  nothing. When EHOS answers that it deployed nothing, the environment it created stays, and the
  error says so. Under `--json`, the answer, or the error, holds the environment it created as
  `created_environment`. Before it acts on an environment named `<application>-pr-<n>`, `deploy`
  says on stderr, unless under `--json`, that the pipeline of a pull request may deploy over it
  and remove it (`Ehosctl.Env.pull_request_warning/2`).

  `--bundle <dir>` deploys a bundle, as `mix eh_os_contract.bundle --output-dir` writes it, in place
  of `--manifest` and `--graph`: its manifest and its graph documents, each checked against the size
  and digest its `bundle.json` gives (`Ehosctl.Bundle`), sent as they would be from their files.
  Deploying from files stays, for an application built outside CI (D-146).

  `--commit` and `--ref` state where the image came from, sent as the parameters `commit` and
  `ref` only when the person gives them: a checkout's commit has no tie to the image deployed, so
  it is never sent for them (eh-os D-129). Their form is checked as EHOS checks it, their truth by
  no one, and EHOS shows them beside the digest as stated by that person. A pipeline's deployment
  is named by the GitHub run its credential was exchanged for, and what it states is not taken.
  What EHOS answers says where the deployment came from, by its kind (`Ehosctl.Source`).

  It needs `ehos.application.deploy` in the environment, and `ehos.application.register` too when
  the manifest puts another authority in force. A refusal is printed in the deploy page's words.

  EHOS answers once the cluster has the deployment's objects, while it is `activating`. `deploy`
  then waits (eh-os#413): it reads the application's deployments in the environment
  (`Ehosctl.Deployments`), after two seconds and then further apart, up to ten seconds, prints
  each state the deployment moves to, and ends when EHOS says it is `active` (exit 0), `failed`,
  with its failure, `superseded`, or `withdrawn` when its ephemeral environment is taken down
  (eh-os D-100) (exit 1, `:failed`), or when ten minutes pass first (exit 5,
  as for anything that may still change: it is said how to look later). A read EHOS did not
  answer is tried again until then; a refusal ends the wait, since EHOS records each one. Against an EHOS older than that
  route it says it cannot follow the deployment there, and exits 0, as it did before. `--no-wait`
  returns at once, as `deploy` did before it waited; whether the deployment became active is then
  on the application's page in the console. Under `--json`, one document at the end: EHOS's
  answer to the deployment, kept to the fields `ehosctl` reads, with its last `state` and
  `failure`, the `outcome` and the `addresses`.

  `ehosctl deploy <application> --env E --manifest <file> --preview` deploys nothing: it prints
  what the deployment would do, as the deploy page shows it before it is confirmed, from
  `POST /api/v1/deployments/preview?environment=E` with the same body (eh-os#373). That is the
  application, and whether EHOS knows it yet; both of the manifest's digests and the version in
  force; what its authority adds and takes away, as `ehosctl apps review` says it
  (`Ehosctl.Review`); whether it also needs `ehos.application.register`; each need's binding;
  the hosts outside the installation it reaches, from an EHOS that says them (eh-os D-135);
  what it changes in sign-in and in reading the company's people; the mail it asks to send
  through EHOS against what the deployments in force there ask, from an EHOS that says it (eh-os
  D-140); the CPU and memory its containers ask for, and whether the environment's quota has room
  for it, from an EHOS that says them (eh-os D-143); and every reason it would be refused. It
  exits 0 when there is none, and 1, `:failed`, with the preview printed, when there is one. The
  preview takes no image, so `--image` is refused with `--preview`.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Bundle
  alias Ehosctl.Deployments
  alias Ehosctl.Env
  alias Ehosctl.Failure
  alias Ehosctl.HTTP
  alias Ehosctl.Mail
  alias Ehosctl.ManifestFile
  alias Ehosctl.Multipart
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.Review
  alias Ehosctl.Source

  require Ehosctl.Api

  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  @in_console "Open the page of the application in the console to see if it became active."

  # EHOS takes at most this many documents with a deployment, and at most this many bytes of them
  # in all (eh-os D-134), and stops reading the body past either; more are refused here, before
  # anything is sent, in the words EHOS answers (`Ehos.Landscape`, `EhosWeb.Plugs.DeploymentParts`).
  @most_graphs 512
  @most_graph_bytes 33_554_432

  @impl Ehosctl.Command
  def name, do: :deploy

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :applications

  @impl Ehosctl.Command
  def summary, do: "Deploy a build to an environment."

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Deploy a build, or an image and its application manifest, to an environment, and wait " <>
          "until the deployment is active. With --preview, show what the deployment would do.",
      args: [
        application: [
          value_name: "APPLICATION",
          required: true,
          help: "The name of the application, as its application manifest names it."
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
            "The image, by digest: <registry>/<repository>@sha256:<digest>. A deployment " <>
              "needs it, unless you give --build. A preview does not accept it."
        ],
        manifest: [
          long: "--manifest",
          value_name: "FILE",
          help:
            "The JSON file of the application manifest, as it was generated. Give - " <>
              "for stdin. Required unless you give --bundle or --build."
        ],
        bundle: [
          long: "--bundle",
          value_name: "DIR",
          help:
            "The directory of a bundle, as `mix eh_os_contract.bundle --output-dir` writes it. " <>
              "It replaces --manifest and --graph. Not accepted with --preview."
        ],
        build: [
          long: "--build",
          value_name: "BUILD",
          help:
            "A build that the pipeline of the application registered: its id from " <>
              "`ehosctl builds list`, a commit, or latest with --ref."
        ],
        template: [
          long: "--template",
          value_name: "TEMPLATE",
          help:
            "With --create-env: the environment template to create the environment from. If " <>
              "you do not give one, EHOS uses the default of the installation."
        ],
        repository: [
          long: "--repository",
          value_name: "OWNER/NAME",
          help:
            "The GitHub repository of the build, with --build and a commit or latest. Required " <>
              "when builds of more than one repository match."
        ],
        commit: [
          long: "--commit",
          value_name: "SHA",
          help:
            "The commit that the image came from, as you state it: 40 or 64 lowercase " <>
              "hexadecimal characters. EHOS shows it beside the digest as your statement. ehosctl " <>
              "never reads it from a checkout."
        ],
        graph: [
          long: "--graph",
          value_name: "FILE",
          multiple: true,
          help:
            "A graph document, as `mix eh_os_contract.graph --output-dir` writes it. Give it " <>
              "once for each document, at most #{@most_graphs}. Not accepted with --preview."
        ],
        ref: [
          long: "--ref",
          value_name: "REF",
          help:
            "With --build latest: the full ref of the build, as GitHub names it, such as " <>
              "refs/heads/main. Without --build: the branch or tag that the image came from, " <>
              "as you state it."
        ]
      ],
      flags:
        [
          preview: [
            long: "--preview",
            help:
              "Show what the deployment would do, and each reason that EHOS would refuse it. " <>
                "Deploy nothing."
          ],
          create_env: [
            long: "--create-env",
            help:
              "With --build: if the environment does not exist, create it first as an " <>
                "ephemeral environment of the application. If EHOS refuses the deployment, the " <>
                "environment stays until it expires."
          ],
          no_role_bindings: Env.no_role_bindings_flag("With --create-env: create"),
          no_wait: [
            long: "--no-wait",
            help:
              "Return when EHOS decides the deployment. Do not wait until the deployment is " <>
                "active or fails, which can take up to 10 minutes."
          ]
        ] ++ Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], %{options: %{build: build}} = parsed, opts) when is_binary(build),
    do: deploy_build(build, parsed, opts)

  def call([], parsed, opts) do
    application = parsed.args.application
    %{env: env, image: image, commit: commit, ref: ref} = parsed.options
    %{preview: preview?, no_wait: no_wait?, json: json?} = parsed.flags
    graphs = parsed.options[:graph] || []

    with :ok <- not_created(parsed),
         :ok <- image(image, preview?),
         {:ok, stated} <- stated(commit, ref, preview?),
         :ok <- graphs(graphs, preview?),
         {:ok, manifest, where, {documents, _bytes} = read} <-
           files(parsed.options, graphs, preview?, opts),
         :ok <- for_application(manifest, where, application) do
      if preview? do
        preview(manifest, application, env, json?, opts)
      else
        sending(read, json?)
        warn_pull_request(application, env, json?)
        query = [environment: env, image: image] ++ stated

        deploy(
          body(manifest, documents),
          {"/api/v1/deployments?" <> URI.encode_query(query), application, env},
          {not no_wait?, json?, nil},
          opts
        )
      end
    end
  end

  # The manifest and the graph documents, from their files or from a bundle (eh-os D-146), which
  # holds both, so it is given in place of them.
  defp files(%{manifest: file, bundle: dir} = options, graphs, preview?, opts) do
    cond do
      is_binary(options.repository) ->
        {:error, :invalid,
         "--repository works only with --build: it narrows the builds that a commit or " <>
           "latest names. Give --build, or leave out --repository."}

      is_binary(dir) and (is_binary(file) or graphs != []) ->
        {:error, :invalid,
         "--bundle replaces --manifest and --graph: the bundle holds the application manifest " <>
           "and the graph documents. Give --bundle, or --manifest and --graph."}

      is_binary(dir) and preview? ->
        {:error, :invalid,
         "--preview does not accept --bundle: EHOS previews only the application manifest. " <>
           "Give --manifest #{Refusal.shown(Path.join(dir, "ehos.manifest.json"))} to preview " <>
           "it."}

      true ->
        read_files(dir, file, graphs, opts)
    end
  end

  defp read_files(dir, _file, _graphs, _opts) when is_binary(dir) do
    with {:ok, bundle} <- Bundle.read(dir),
         do:
           {:ok, bundle.manifest, Refusal.shown(Path.join(dir, "ehos.manifest.json")),
            {bundle.graphs, bundle.graph_bytes}}
  end

  defp read_files(_dir, file, graphs, opts) when is_binary(file) do
    with {:ok, manifest} <- ManifestFile.read(file, opts),
         {:ok, read} <- documents(graphs, opts),
         do: {:ok, manifest, ManifestFile.where(file), read}
  end

  defp read_files(_dir, _file, _graphs, _opts),
    do:
      {:error, :invalid,
       "Nothing to deploy. Give --build with a build that the pipeline registered, " <>
         "--bundle with the directory of a bundle, or --manifest with --image."}

  # As the image is: the preview reads the manifest alone, so documents it would not read are
  # refused rather than ignored.
  defp graphs([_ | _], true),
    do:
      {:error, :invalid,
       "--preview does not accept --graph: EHOS previews only the application manifest. Give " <>
         "the graph documents when you deploy."}

  defp graphs(graphs, _preview?) when length(graphs) > @most_graphs,
    do:
      {:error, :invalid,
       "You gave #{length(graphs)} graph documents, and a deployment takes at most " <>
         "#{@most_graphs}. ehosctl sent nothing."}

  # stdin is the manifest's, or nothing's: a document named - would be read after it, and empty.
  defp graphs(graphs, _preview?) do
    if "-" in graphs,
      do:
        {:error, :invalid,
         "--graph takes a file: ehosctl does not read a graph document from stdin, and sent " <>
           "nothing."},
      else: :ok
  end

  # Read one at a time, the bytes summed as they are, so documents past the bound in all are
  # refused without holding more of them than it.
  defp documents(files, opts) do
    opts = Keyword.put(opts, :what, "graph document")

    Enum.reduce_while(files, {:ok, [], 0}, fn file, {:ok, read, bytes} ->
      with {:ok, document} <- ManifestFile.read(file, opts),
           bytes = bytes + byte_size(document),
           :ok <- in_all(bytes) do
        {:cont, {:ok, [document | read], bytes}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, read, bytes} ->
        {:ok, {Enum.reverse(read), bytes}}

      error ->
        error
    end
  end

  # Said once nothing is left to refuse here, before the credential is fetched and the request
  # made, on stderr; not under `--json`, whose stderr holds a refusal's document alone, as
  # `follow/5` says nothing either.
  defp sending({[], _bytes}, _json?), do: :ok
  defp sending(_documents, true), do: :ok

  defp sending({documents, bytes}, false) do
    IO.puts(
      :stderr,
      "Sending with the application manifest: #{count(length(documents))}, #{bytes} bytes " <>
        "in all."
    )
  end

  defp in_all(bytes) when bytes > @most_graph_bytes,
    do:
      {:error, :invalid,
       "The graph documents are larger than #{@most_graph_bytes} bytes in all, the most that " <>
         "a deployment takes. ehosctl sent nothing."}

  defp in_all(_bytes), do: :ok

  defp count(1), do: "1 graph document"
  defp count(n), do: "#{n} graph documents"

  # eh-os#785: the manifest alone as before, or with the documents as a multipart body, the
  # manifest's part first, each part the bytes of its file.
  defp body(manifest, []), do: {:raw, "application/json", manifest}

  defp body(manifest, documents),
    do: Multipart.body([{"manifest", manifest} | Enum.map(documents, &{"graph", &1})])

  # As the image is: the preview reads the manifest alone, so what it would not check is refused.
  defp stated(nil, nil, true), do: {:ok, []}

  defp stated(_commit, _ref, true),
    do:
      {:error, :invalid,
       "--preview does not accept --commit or --ref: EHOS previews only the application " <>
         "manifest. Give them when you deploy."}

  defp stated(commit, ref, false), do: Source.stated(commit, ref)

  # EHOS's preview reads the manifest alone: the route takes no image. An image given with
  # `--preview` would be checked by nothing, and a preview that passed would seem to say it was
  # (the deploy page checks it is pinned by digest before it previews). It is refused rather than
  # ignored, so that what a preview prints is all it checked.
  defp image(nil, false),
    do:
      {:error, :invalid,
       "A deployment needs --image, the image by digest: " <>
         "<registry>/<repository>@sha256:<digest>. To see what the deployment would do " <>
         "without an image, give --preview."}

  defp image(_image, false), do: :ok
  defp image(nil, true), do: :ok

  defp image(_image, true),
    do:
      {:error, :invalid,
       "--preview does not accept --image: EHOS previews only the application manifest, and " <>
         "checks the image when you deploy. Remove --image from the preview."}

  # `created`, the environment `--create-env` created for the deployment, or `nil`: under `--json`
  # it is in the answer, and if EHOS refuses the deployment, it is said to stay.
  defp deploy(body, {path, application, env}, {wait?, json?, created}, opts) do
    installation = Keyword.fetch!(opts, :installation)

    sent = Api.answer(installation, :post, path, body, opts)

    case answered(sent, installation, application, env) do
      {:ok, body} when wait? ->
        body |> with_created(created) |> follow(application, env, json?, opts)

      {:ok, body} ->
        text = deployed(body, application, env) <> "\n" <> @in_console
        {:ok, %{text: text, json: with_created(body, created)}}

      error ->
        created_error(error, created, nothing_deployed?(sent))
    end
  end

  defp with_created(body, nil), do: body
  defp with_created(body, created), do: Map.put(body, "created_environment", created)

  # The environment `--create-env` created is named under `--json` whatever the error. It is said to
  # stay, with how to remove it, only when nothing was deployed there: a deployment that went
  # unanswered, or that a gateway answered, may have been, and one decided and then superseded or
  # failed was, and another may run there now.
  defp created_error(error, nil, _nothing_deployed?), do: error

  defp created_error(error, %{"name" => name} = created, true) do
    error
    |> created_error(created, false)
    |> Refusal.added(
      "\nThe ephemeral environment #{Refusal.shown(name)}, which ehosctl created for the " <>
        "deployment, stays until it expires. Run `ehosctl env remove #{Refusal.shown(name)}` " <>
        "to remove it."
    )
  end

  defp created_error({:error, kind, message}, created, false),
    do: {:error, kind, message, %{"created_environment" => created}}

  defp created_error({:error, kind, message, refusal}, created, false),
    do: {:error, kind, message, Map.put(refusal, "created_environment", created)}

  defp nothing_deployed?({:error, _kind, _message, :sent}), do: false

  defp nothing_deployed?({:ok, %{status: status, body: body}}),
    do:
      not (is_map(body) and is_map_key(body, "deployment")) and
        (status in 400..499 or (status >= 500 and Api.coded?(body)))

  defp nothing_deployed?(_not_sent), do: true

  defp for_application(manifest, where, application) do
    case JSON.decode(manifest) do
      {:ok, %{"application" => ^application}} ->
        :ok

      {:ok, %{"application" => other}} when is_binary(other) ->
        {:error, :invalid,
         "#{where} is the application manifest of #{Refusal.shown(other)}, not of " <>
           "#{Refusal.shown(application)}. ehosctl sent nothing."}

      {:ok, %{"application" => _other}} ->
        {:error, :invalid,
         "#{where} is not an application manifest: its application is not text."}

      {:ok, %{}} ->
        {:error, :invalid,
         "#{where} is not an application manifest: it does not name an application."}

      _other ->
        {:error, :invalid,
         "#{where} is not an application manifest: it does not hold a JSON object."}
    end
  end

  # ehos-tools#364: the answer's fields read, so one a later EHOS adds reaches no script under
  # `--json`, as a history and a preview are kept.
  @answered ~w(deployment image digest authority_digest state source failure build)

  defp answered({:ok, %{status: 201, body: body}}, installation, application, env) do
    if is_map(body) and deployment?(body) do
      {:ok, body |> Map.take(@answered) |> Source.keeping()}
    else
      {:error, kind, message} = Api.unexpected(installation)

      {:error, kind,
       Failure.added(
         message,
         " EHOS answered 201, so it decided the deployment. Open the page of " <>
           "#{Refusal.shown(application)} in the console to see it in #{Refusal.shown(env)}."
       )}
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
    failure =
      if is_binary(body["failure"]), do: " Its failure: #{Refusal.shown(body["failure"])}."

    answer
    |> Api.refusal(installation)
    |> Refusal.added(" Deployment #{Refusal.shown(id)}.#{failure}")
  end

  # eh-os D-146: a build that is not found, or one of several repositories, says how to name it.
  defp answered(
         {:ok, %{status: 404, body: %{"error" => "build_not_found"}} = answer},
         installation,
         application,
         _env
       ) do
    answer
    |> Api.refusal(installation)
    |> Refusal.added(
      " Run `ehosctl builds list #{Refusal.shown(application)}` to see the builds of the " <>
        "application."
    )
  end

  # eh-os D-105: production takes a version only by a promotion of a candidate.
  defp answered(
         {:ok, %{status: 409, body: %{"error" => "promotion_required"}} = answer},
         installation,
         application,
         env
       ) do
    app = Refusal.shown(application)

    answer
    |> Api.refusal(installation)
    |> Refusal.added(
      " Deploy the version to an ephemeral environment of #{app} first. Then run " <>
        "`ehosctl promote #{app} --candidate DEPLOYMENT --env #{Refusal.shown(env)}`."
    )
  end

  defp answered(
         {:ok, %{status: 422, body: %{"error" => "repository_required"}} = answer},
         installation,
         _application,
         _env
       ) do
    answer
    |> Api.refusal(installation)
    |> Refusal.added(" Give the repository with --repository owner/name.")
  end

  defp answered({:ok, %{status: 422} = answer}, installation, _application, _env),
    do: ManifestFile.refused(answer, installation)

  # A 5xx with no code of EHOS's own, such as a gateway's timeout, may have come after the
  # deployment was decided.
  defp answered({:ok, %{status: status} = answer}, installation, application, env)
       when status >= 500 do
    refused = Api.refusal(answer, installation)

    if Api.coded?(answer.body),
      do: refused,
      else: Refusal.added(refused, maybe_deployed(application, env))
  end

  defp answered({:ok, answer}, installation, _application, _env),
    do: Api.refusal(answer, installation)

  defp answered({:error, kind, message, :sent}, _installation, application, env),
    do: {:error, kind, Failure.added(message, maybe_deployed(application, env))}

  defp answered(error, _installation, _application, _env), do: error

  defp maybe_deployed(application, env),
    do:
      " EHOS may have deployed it. Before you deploy again, open the page of " <>
        "#{Refusal.shown(application)} in the console and look at #{Refusal.shown(env)}."

  defp deployment?(body),
    do: Enum.all?(~w(deployment image digest authority_digest state), &is_binary(body[&1]))

  defp deployed(body, application, env) do
    source = Source.line(body["source"])

    Enum.join(
      [
        "Deployed #{Refusal.shown(application)} to #{Refusal.shown(env)}: deployment " <>
          "#{Refusal.shown(body["deployment"])} is #{Refusal.shown(body["state"])}.",
        "  image:            #{Refusal.shown(body["image"])}"
      ] ++
        if(is_binary(body["build"]),
          do: ["  build:            #{Refusal.shown(body["build"])}"],
          else: []
        ) ++
        if(source, do: ["  source:           #{source}"], else: []) ++
        [
          "  manifest digest:  #{Refusal.shown(body["digest"])}",
          "  authority digest: #{Refusal.shown(body["authority_digest"])}"
        ],
      "\n"
    )
  end

  # The deployment as EHOS decided it, then each state it moves to. A read that fails while it
  # waits leaves the deployment standing, and an environment `--create-env` created for it too,
  # named under `--json`.
  defp follow(body, application, env, json?, opts) do
    installation = Keyword.fetch!(opts, :installation)

    if not json?, do: IO.puts(deployed(body, application, env))

    case Deployments.follow(installation, {application, env}, body, json?, opts) do
      code when is_integer(code) -> code
      error -> created_error(error, body["created_environment"], false)
    end
  end

  ## A build

  # eh-os D-146: a build is named, and deployed with no body, since it holds its image, its
  # manifest and its graph documents. What EHOS would refuse beside it is refused here.
  defp deploy_build(build, parsed, opts) do
    application = parsed.args.application
    %{env: env, ref: ref, repository: repository} = parsed.options
    %{no_wait: no_wait?, json: json?} = parsed.flags

    with :ok <- alone(parsed),
         :ok <- template_created(parsed),
         :ok <- entries_created(parsed),
         {:ok, query} <- built(build, ref, repository),
         :ok <- warn_pull_request(application, env, json?),
         {:ok, created} <- environment(parsed, opts) do
      query = [environment: env, application: application] ++ query

      deploy(
        :none,
        {"/api/v1/deployments?" <> URI.encode_query(query), application, env},
        {not no_wait?, json?, created},
        opts
      )
    end
  end

  # Not under `--json`, whose stderr holds a refusal's document alone; the template's pipeline,
  # the pull request's own run, deploys with it.
  defp warn_pull_request(_application, _env, true), do: :ok
  defp warn_pull_request(application, env, false), do: Env.warn_pull_request(application, env)

  # eh-os D-156: as the console's deploy page, `--create-env` creates the ephemeral environment
  # first when there is none of that name: two decisions, each refused or recorded on its own.
  # EHOS counts before it checks the name, so whether one exists is read first: at the count, a
  # creation of one that exists is refused as one too many. A person or an agent who may create
  # one may read it; a pipeline's credential may not, and is told how to do without.
  defp environment(%{flags: %{create_env: false}}, _opts), do: {:ok, nil}

  defp environment(%{args: %{application: application}, options: options} = parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    env = options.env

    if Api.is_nameless(env) do
      {:error, :invalid, "#{Refusal.shown(env)} is not the name of an environment."}
    else
      installation
      |> Api.answer(:get, "/api/v1/environments/" <> Api.segment(env), nil, opts)
      |> existing(installation, {application, env, creation(parsed), parsed.flags.json}, opts)
    end
  end

  # An environment that exists got what its environment template held when EHOS made it, which
  # `--no-role-bindings` cannot take away: one EHOS says it made with them is refused. EHOS says
  # null for an environment that is not ephemeral, and an EHOS older than D-161 says nothing, so
  # each of those is deployed to; for an ephemeral one of the second, stderr says it is not known.
  defp existing(
         {:ok, %{status: 200, body: %{"environment" => %{"template_entries" => true}}}},
         _installation,
         {application, env, {_template, false}, _json?},
         _opts
       ),
       do:
         {:error, :invalid,
          "EHOS made #{Refusal.shown(env)} with the role entries and the people agreement of " <>
            "its environment template, and --no-role-bindings cannot take them away. ehosctl " <>
            "deployed nothing. Deploy without --no-role-bindings, or create another environment " <>
            "with `ehosctl env create ENVIRONMENT --app #{Refusal.shown(application)} " <>
            "--no-role-bindings` and deploy to it."}

  defp existing(
         {:ok, %{status: 200, body: %{"environment" => %{"type" => "ephemeral"} = found}}},
         _installation,
         {_application, env, {_template, false}, false},
         _opts
       )
       when not is_map_key(found, "template_entries") do
    IO.puts(
      :stderr,
      "EHOS did not say if it made #{Refusal.shown(env)} with the role entries and the people " <>
        "agreement of its environment template. ehosctl deploys to it: --no-role-bindings " <>
        "applies only to an environment that ehosctl creates."
    )

    {:ok, nil}
  end

  defp existing({:ok, %{status: 200}}, _installation, _creation, _opts), do: {:ok, nil}

  defp existing(
         {:ok, %{status: 404, body: %{"error" => "not_found"}}},
         _installation,
         {application, env, {template, entries?}, json?},
         opts
       ) do
    with {:ok, %{text: text, json: %{"environment" => created}}} <-
           Env.create_ephemeral(env, application, template, entries?, opts) do
      if not json?, do: IO.puts(:stderr, text)
      {:ok, created}
    end
  end

  defp existing(
         {:ok, %{body: %{"error" => "deployment_identity"}} = answer},
         installation,
         {application, env, {template, entries?}, _json?},
         _opts
       ) do
    template = if template, do: " --template #{Refusal.shown(template)}", else: ""
    template = if entries?, do: template, else: template <> " --no-role-bindings"

    answer
    |> Api.refusal(installation)
    |> Refusal.added(
      " --create-env reads the environment first, which a pipeline's credential cannot. In a " <>
        "GitHub Actions job, run `ehosctl env create #{Refusal.shown(env)} --app " <>
        "#{Refusal.shown(application)}#{template}` if the environment does not exist, then " <>
        "deploy without --create-env."
    )
  end

  defp existing({:ok, answer}, installation, _creation, _opts),
    do: Api.refusal(answer, installation)

  defp existing({:error, _kind, _message, :sent} = unanswered, _installation, _creation, _opts),
    do: HTTP.unanswered_read(unanswered)

  defp existing(error, _installation, _creation, _opts), do: error

  defp template_created(%{options: %{template: template}, flags: %{create_env: false}})
       when is_binary(template),
       do:
         {:error, :invalid,
          "--template works only with --create-env: it names the environment template of the " <>
            "environment that ehosctl creates. Give --create-env, or remove --template."}

  defp template_created(_parsed), do: :ok

  # What `--create-env` creates the environment from: its environment template, and whether it
  # gets the role entries and the people agreement that the environment template holds.
  defp creation(%{options: options, flags: flags}),
    do: {options.template, not flags.no_role_bindings}

  defp entries_created(%{flags: %{no_role_bindings: true, create_env: false}}),
    do:
      {:error, :invalid,
       "--no-role-bindings works only with --create-env: it applies to the environment that " <>
         "ehosctl creates. Give --create-env, or remove --no-role-bindings."}

  defp entries_created(_parsed), do: :ok

  # As the console offers a new environment only for a build (eh-os D-156).
  defp not_created(%{flags: %{create_env: true}}),
    do:
      {:error, :invalid,
       "--create-env works only with --build. Create the environment with `ehosctl env create " <>
         "--app`, or deploy a build with --build."}

  defp not_created(%{options: %{template: template}}) when is_binary(template),
    do:
      {:error, :invalid,
       "--template works only with --build and --create-env. Remove --template."}

  defp not_created(%{flags: %{no_role_bindings: true}}),
    do:
      {:error, :invalid,
       "--no-role-bindings works only with --build and --create-env. Remove " <>
         "--no-role-bindings."}

  defp not_created(_parsed), do: :ok

  defp alone(parsed) do
    case given(parsed) do
      [] ->
        :ok

      given ->
        {:error, :invalid,
         "--build does not accept #{Enum.join(given, ", ")}: a build holds its own image, " <>
           "application manifest and graph documents. ehosctl sent nothing."}
    end
  end

  defp given(%{options: options, flags: flags}) do
    [
      options.image && "--image",
      options.manifest && "--manifest",
      options.bundle && "--bundle",
      (options[:graph] || []) != [] && "--graph",
      options.commit && "--commit",
      flags.preview && "--preview"
    ]
    |> Enum.filter(&is_binary/1)
  end

  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  # `latest` with its ref in full, as GitHub's token names it; a commit; or a build's id. A
  # repository narrows a commit or `latest`, and an id names one build of its own.
  defp built("latest", nil, _repository),
    do:
      {:error, :invalid,
       "--build latest needs --ref, the full ref of the build, such as refs/heads/main or " <>
         "refs/pull/42/merge."}

  defp built("latest", ref, repository) do
    with {:ok, _stated} <- Source.stated(nil, ref) do
      if String.starts_with?(ref, "refs/"),
        do: {:ok, [build: "latest", ref: ref] ++ repository(repository)},
        else:
          {:error, :invalid,
           "--ref #{Refusal.shown(ref)} is not a full ref. With --build latest, give the ref " <>
             "as GitHub names it, such as refs/heads/#{Refusal.shown(ref)}."}
    end
  end

  defp built(build, ref, repository) do
    cond do
      ref != nil ->
        {:error, :invalid,
         "--ref works only with --build latest: a commit or the id of a build names the " <>
           "build without a ref. Remove --ref."}

      Regex.match?(@commit, build) ->
        {:ok, [build: build] ++ repository(repository)}

      repository != nil and Api.uuid?(build) ->
        {:error, :invalid,
         "--repository works only with a commit or latest: the id of a build names one build. " <>
           "Remove --repository."}

      Api.uuid?(build) ->
        {:ok, [build: String.downcase(build)]}

      true ->
        {:error, :invalid,
         "--build #{Refusal.shown(build)} does not name a build. Give its id from " <>
           "`ehosctl builds list`, a commit of 40 or 64 lowercase hexadecimal characters, or " <>
           "latest with --ref."}
    end
  end

  defp repository(nil), do: []
  defp repository(repository), do: [repository: repository]

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
  defp previewed(
         {:error, _kind, _message, :sent} = unanswered,
         _installation,
         _application,
         _env
       ),
       do: HTTP.unanswered_read(unanswered)

  defp previewed(error, _installation, _application, _env), do: error

  defp preview?(
         %{"application" => application, "environment" => env} = preview,
         application,
         env
       ),
       do: decided?(preview) and needs?(preview) and asks?(preview)

  defp preview?(_preview, _application, _env), do: false

  defp decided?(preview),
    do:
      is_boolean(preview["known"]) and digest?(preview["digest"]) and
        digest?(preview["authority_digest"]) and
        (is_nil(preview["in_force"]) or digest?(preview["in_force"])) and
        preview["authority"] in ["changed", "unchanged"] and Review.changes?(preview)

  defp needs?(preview),
    do:
      register?(preview["register"]) and all?(preview["needs"], &need?/1) and
        all?(Map.get(preview, "egress", []), &host?/1) and
        sign_in?(preview["sign_in"]) and people?(preview["people"])

  defp asks?(preview),
    do:
      mail?(preview["mail"]) and mail?(preview["mail_in_force"]) and
        compute?(preview["compute"]) and room?(preview["room"]) and
        all?(preview["refusals"], &is_binary/1)

  defp register?(%{"needed" => needed, "held" => held}),
    do: is_boolean(needed) and is_boolean(held)

  defp register?(_register), do: false

  defp need?(%{"need" => need, "engine" => engine} = asked)
       when is_binary(need) and is_binary(engine),
       do: nil_or_text?(asked["version"]) and binding?(asked)

  defp need?(_need), do: false

  # eh-os D-135: a host outside the installation the manifest names, with its port; absent from
  # an EHOS that predates `needs.egress`, and then none. eh-os D-141: whether it is the
  # installation's mail relay, absent from an EHOS before that, and then not.
  defp host?(%{"host" => host, "port" => port} = egress) when is_binary(host),
    do:
      is_integer(port) and port in 1..65_535 and
        Map.get(egress, "mail_relay", false) in [true, false]

  defp host?(_host), do: false

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

  # eh-os D-140: whom the workload writes to and where the answers go, or nil when it asks to send
  # none; absent from an EHOS that predates mail, and then none.
  defp mail?(nil), do: true

  defp mail?(%{"level" => level, "reply_domains" => domains})
       when level in ["internal", "external"],
       do: all?(domains, &is_binary/1)

  defp mail?(_mail), do: false

  # eh-os D-143: the CPU and memory its containers ask for, each a quantity or null for the
  # environment's default, or nil when it names none; absent from an EHOS before that, and then
  # not said.
  defp compute?(nil), do: true

  defp compute?(%{} = compute),
    do: nil_or_text?(compute["cpu"]) and nil_or_text?(compute["memory"])

  defp compute?(_compute), do: false

  # Whether the environment's quota has room for it with a second pod for its rollout, and whose
  # quota that is; absent from an EHOS before eh-os D-143.
  defp room?(nil), do: true
  defp room?(%{"fits" => fits, "whose" => whose}), do: is_boolean(fits) and is_binary(whose)
  defp room?(_room), do: false

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
      "egress" => Enum.map(Map.get(preview, "egress", []), &only_egress/1),
      "sign_in" => sign_in,
      "people" => preview["people"],
      "mail" => only_mail(preview["mail"]),
      "mail_in_force" => only_mail(preview["mail_in_force"]),
      "compute" => preview["compute"] && Map.take(preview["compute"], ~w(cpu memory)),
      "room" => preview["room"] && Map.take(preview["room"], ~w(fits whose))
    })
  end

  # An EHOS before eh-os D-141 did not check for the relay: its hosts carry no mark, and keep none,
  # so a script tells "not checked" from "not the relay".
  defp only_egress(egress), do: Map.take(egress, ~w(host port mail_relay))

  defp only_mail(nil), do: nil
  defp only_mail(mail), do: Map.take(mail, ~w(level reply_domains))

  # The deploy page's words for each part of the preview (eh-os `EhosWeb.DeployLive`).
  defp preview_text(preview) do
    app = Refusal.shown(preview["application"])
    env = Refusal.shown(preview["environment"])

    [
      [
        "What a deployment of #{app} to #{env} would do. ehosctl deployed nothing.",
        "  manifest digest:  #{Refusal.shown(preview["digest"])}",
        "  authority digest: #{Refusal.shown(preview["authority_digest"])}",
        "  in force now:     #{Refusal.shown(preview["in_force"] || "none")}"
      ],
      not preview["known"] &&
        [
          "EHOS does not know #{app} yet. This deployment registers it, with this application " <>
            "manifest as its first version."
        ],
      preview["register"] == %{"needed" => true, "held" => true} &&
        [
          "This deployment puts another authority in force in #{env}, so it also needs " <>
            "ehos.application.register there. You hold it."
        ],
      authority(preview, env),
      needs(preview["needs"]),
      egress(Map.get(preview, "egress", [])),
      relay(Map.get(preview, "egress", []), app),
      sign_in(preview["sign_in"], app, env),
      people(preview["people"], app, env),
      mail(preview["mail"], preview["mail_in_force"], env),
      compute(preview["compute"], preview["room"], env),
      refusals(preview["refusals"])
    ]
    |> Enum.filter(&is_list/1)
    |> Enum.map_join("\n\n", &Enum.join(&1, "\n"))
  end

  defp authority(preview, env) do
    case {Review.lines(preview), preview["in_force"]} do
      {[], _in_force} ->
        [
          "This application manifest grants what the version in force grants. The deployment " <>
            "changes the authority of no one in #{env}."
        ]

      # With nothing in force, there is nothing for its authority to differ from.
      {_lines, nil} ->
        case Review.named(preview) do
          [] ->
            [
              "Nothing is in force in #{env}, and the authority of this application manifest " <>
                "names no capability and no role."
            ]

          named ->
            ["Nothing is in force in #{env}. What the authority of this version adds:" | named]
        end

      {lines, _in_force} ->
        ["What its authority adds and removes, compared with the version in force:" | lines]
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

  defp egress([]), do: nil

  defp egress(hosts) do
    [
      "Hosts outside the installation it reaches: " <>
        Enum.map_join(hosts, ", ", &hostport/1)
    ]
  end

  # eh-os D-141: a host that is the installation's mail relay, which the approver should know.
  defp relay(hosts, app) do
    case Mail.relay(for(%{"mail_relay" => true} = host <- hosts, do: hostport(host)), app) do
      nil -> nil
      said -> [said]
    end
  end

  defp hostport(host), do: "#{Refusal.shown(host["host"])}:#{host["port"]}"

  defp bound(%{"bound" => bound}), do: Refusal.shown(bound)
  defp bound(%{"refused" => why}), do: "cannot be bound: " <> Refusal.shown(why)

  # A need may ask for no version: its engine alone is shown.
  defp asks(%{"engine" => engine, "version" => version}) when is_binary(version),
    do: "#{Refusal.shown(engine)} #{Refusal.shown(version)}"

  defp asks(%{"engine" => engine}), do: Refusal.shown(engine)

  defp sign_in(nil, _app, _env), do: nil

  defp sign_in(%{"adds" => adds, "applications" => applications}, app, env) do
    added =
      "This deployment signs people in to #{app} through EHOS. Its workload becomes a client " <>
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
          else: "none until a person who can deploy #{name} in #{env} agrees"

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
      "This deployment stops reading the people of the company. The deployment in force in " <>
        "#{env} asks to read them, and this one does not."
    ]

  defp people(%{"adds" => true}, app, env),
    do: [
      "This deployment asks to read the people of the company. EHOS gives #{app} a key to " <>
        "identify itself in #{env}. #{app} reads the people only after a person who manages " <>
        "people agrees there."
    ]

  defp people(%{"adds" => false}, _app, _env),
    do: [
      "This deployment reads the people of the company, as the deployment in force there " <>
        "does, after a person who manages people agrees."
    ]

  # eh-os D-140: what the deployment asks of mail, against the deployments in force there, in the
  # deploy page's words (`EhosWeb.DeployLive`). EHOS sends it, but only as far as the mail
  # agreement for the environment allows, once someone who holds `ehos.mail.manage` gives it.
  defp mail(nil, nil, _env), do: nil

  defp mail(nil, in_force, env),
    do: [
      "This deployment asks to send no mail. The deployment in force in #{env} asks to " <>
        "#{asked(in_force)}, so the workload stops sending."
    ]

  defp mail(mail, nil, env),
    do: [
      "This deployment asks to #{asked(mail)}. A person who holds ehos.mail.manage agrees " <>
        "in #{env}, on the Installation page or with `ehosctl mail agree`. The workload sends " <>
        "only as far as that mail agreement allows."
    ]

  defp mail(mail, in_force, env) do
    said =
      [
        level_change(in_force["level"], mail["level"]),
        domains_change("adds replies to", mail["reply_domains"] -- in_force["reply_domains"]),
        domains_change("drops replies to", in_force["reply_domains"] -- mail["reply_domains"])
      ]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> "as the deployment in force there does"
        changes -> Enum.join(changes, "; ")
      end

    [
      "This deployment asks to #{asked(mail)}: #{said}. The workload sends only as far as " <>
        "the mail agreement in #{env} allows."
    ]
  end

  defp asked(mail), do: "send mail through EHOS " <> Ehosctl.Mail.whom(mail)

  # eh-os D-143: what its containers ask for, and whether the environment has room for it with a
  # second pod for its rollout, in the deploy page's words; why not is among the refusals. Said
  # only by an EHOS that says the room.
  defp compute(_compute, nil, _env), do: nil

  defp compute(compute, %{"fits" => fits, "whose" => whose}, env) do
    asked =
      if compute,
        do:
          "Its containers ask for #{cpu_said(compute["cpu"])} and #{memory_said(compute["memory"])}.",
        else: "Its containers take the defaults of #{env}."

    room =
      if fits,
        do: "It fits #{Refusal.shown(whose)}, with room for its rollout.",
        else: "It does not fit #{Refusal.shown(whose)}, as the refusals below say."

    [asked <> " " <> room]
  end

  defp cpu_said(nil), do: "the environment's default CPU"
  defp cpu_said(cpu), do: "#{Refusal.shown(cpu)} of CPU"

  defp memory_said(nil), do: "the environment's default memory"

  defp memory_said(memory),
    do: "#{Refusal.shown(memory)} of memory, which is also the most each may use"

  defp listed(domains), do: Ehosctl.Mail.listed(domains)

  defp level_change("internal", "external"),
    do: "wider than the deployment in force, which writes only to the people of the company"

  defp level_change("external", "internal"),
    do: "narrower than the deployment in force, which writes to any address"

  defp level_change(_same, _level), do: nil

  defp domains_change(_verb, []), do: nil
  defp domains_change(verb, domains), do: "#{verb} #{listed(domains)}"

  defp refusals([]),
    do: [
      "To deploy it, run the command again without --preview, and give the image with --image."
    ]

  defp refusals([reason]),
    do: ["EHOS would refuse the deployment, for this reason:", "  - " <> Refusal.shown(reason)]

  defp refusals(reasons),
    do: [
      "EHOS would refuse the deployment, for these reasons:"
      | Enum.map(reasons, &("  - " <> Refusal.shown(&1)))
    ]
end
