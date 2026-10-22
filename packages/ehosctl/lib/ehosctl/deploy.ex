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
  what it changes in sign-in and in reading the company's people; and every reason it would be
  refused. It exits 0 when there is none, and 1, `:failed`, with the preview printed, when there
  is one. The preview takes no image, so `--image` is refused with `--preview`.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Deployments
  alias Ehosctl.ManifestFile
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.Review
  alias Ehosctl.Source

  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  # How often the deployment is read while waiting, and for how long at most; each injectable.
  @poll_ms 2_000
  @poll_max_ms 10_000
  # The most deployments EHOS lists in one answer.
  @listed_most 50
  @wait_ms 600_000

  @in_console "Whether it became active is on the application's page in the console."

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
  def spec,
    do: [
      about:
        "Deploy an image, by digest, with its manifest, to an environment, and wait until it " <>
          "is active; or preview what deploying the manifest would do.",
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
        ],
        commit: [
          long: "--commit",
          value_name: "SHA",
          help:
            "The commit the image was built from, as you state it: 40 or 64 lowercase " <>
              "hexadecimal characters. Shown beside its digest as stated by you; never taken from a checkout."
        ],
        graph: [
          long: "--graph",
          value_name: "FILE",
          multiple: true,
          help:
            "A graph document of the application, a domain's, a contract's or a process " <>
              "module's, as mix eh_os_contract.graph --output-dir writes them, sent with the " <>
              "manifest; once for each document, at most #{@most_graphs}. Not taken with --preview."
        ],
        ref: [
          long: "--ref",
          value_name: "REF",
          help:
            "The branch or tag the image was built from, as you state it, such as " <>
              "refs/heads/main. Shown beside its digest as stated by you."
        ]
      ],
      flags:
        [
          preview: [
            long: "--preview",
            help:
              "Print what the deployment would do, and every reason it would be refused; deploy nothing."
          ],
          no_wait: [
            long: "--no-wait",
            help:
              "Return once EHOS has decided the deployment, without waiting until it is active " <>
                "(at most ten minutes) or has failed."
          ]
        ] ++ Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    application = parsed.args.application
    %{env: env, image: image, manifest: file, commit: commit, ref: ref} = parsed.options
    %{preview: preview?, no_wait: no_wait?, json: json?} = parsed.flags
    graphs = parsed.options[:graph] || []

    with :ok <- image(image, preview?),
         {:ok, stated} <- stated(commit, ref, preview?),
         :ok <- graphs(graphs, preview?),
         {:ok, manifest} <- ManifestFile.read(file, opts),
         :ok <- for_application(manifest, file, application),
         {:ok, {documents, _bytes} = read} <- documents(graphs, opts) do
      if preview? do
        preview(manifest, application, env, json?, opts)
      else
        sending(read, json?)

        deploy(
          body(manifest, documents),
          {application, env, image, stated},
          {not no_wait?, json?},
          opts
        )
      end
    end
  end

  # As the image is: the preview reads the manifest alone, so documents it would not read are
  # refused rather than ignored.
  defp graphs([_ | _], true),
    do:
      {:error, :invalid,
       "--preview takes no --graph: EHOS previews the manifest alone. Give the graph documents " <>
         "to deploy."}

  defp graphs(graphs, _preview?) when length(graphs) > @most_graphs,
    do:
      {:error, :invalid,
       "The deployment brings more than #{@most_graphs} graph documents, the most it may " <>
         "carry: #{length(graphs)} were given. Nothing was sent."}

  # stdin is the manifest's, or nothing's: a document named - would be read after it, and empty.
  defp graphs(graphs, _preview?) do
    if "-" in graphs,
      do:
        {:error, :invalid,
         "--graph takes a file: a graph document is not read from stdin. Nothing was sent."},
      else: :ok
  end

  # Read one at a time, the bytes summed as they are, so documents past the bound in all are
  # refused without holding more of them than it.
  defp documents(files, opts) do
    larger = "A graph document is larger than #{ManifestFile.max_bytes()} bytes"
    opts = Keyword.merge(opts, what: "graph document", larger: larger)

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
      "With the manifest: #{count(length(documents))}, #{bytes} bytes in all."
    )
  end

  defp in_all(bytes) when bytes > @most_graph_bytes,
    do:
      {:error, :invalid,
       "The graph documents are larger than #{@most_graph_bytes} bytes in all. Nothing was sent."}

  defp in_all(_bytes), do: :ok

  defp count(1), do: "1 graph document"
  defp count(n), do: "#{n} graph documents"

  # eh-os#785: the manifest alone as before, or with the documents as a multipart body, the
  # manifest's part first, each part the bytes of its file. The boundary is random, and drawn again
  # in the unlikely case one of the parts holds it.
  defp body(manifest, []), do: {:raw, "application/json", manifest}

  defp body(manifest, documents) do
    parts = [{"manifest", manifest} | Enum.map(documents, &{"graph", &1})]
    boundary = boundary(parts)

    bytes =
      IO.iodata_to_binary([
        for {name, part} <- parts do
          [
            "--",
            boundary,
            "\r\ncontent-disposition: form-data; name=\"",
            name,
            "\"\r\ncontent-type: application/json\r\n\r\n",
            part,
            "\r\n"
          ]
        end,
        "--",
        boundary,
        "--\r\n"
      ])

    {:raw, "multipart/form-data; boundary=" <> boundary, bytes}
  end

  defp boundary(parts) do
    boundary = "ehosctl-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    if Enum.any?(parts, fn {_name, part} -> String.contains?(part, boundary) end),
      do: boundary(parts),
      else: boundary
  end

  # As the image is: the preview reads the manifest alone, so what it would not check is refused.
  defp stated(nil, nil, true), do: {:ok, []}

  defp stated(_commit, _ref, true),
    do:
      {:error, :invalid,
       "--preview takes no --commit or --ref: EHOS previews the manifest alone. Give them to " <>
         "deploy."}

  defp stated(commit, ref, false), do: Source.stated(commit, ref)

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

  defp deploy(body, {application, env, image, stated}, {wait?, json?}, opts) do
    installation = Keyword.fetch!(opts, :installation)
    path = "/api/v1/deployments?" <> URI.encode_query([environment: env, image: image] ++ stated)

    answer =
      installation
      |> Api.answer(:post, path, body, opts)
      |> answered(installation, application, env)

    case answer do
      {:ok, body} when wait? ->
        follow(body, application, env, json?, opts)

      {:ok, body} ->
        text = deployed(body, application, env) <> "\n" <> @in_console
        {:ok, %{text: text, json: body}}

      error ->
        error
    end
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

  # #364: the answer's fields read, so one a later EHOS adds reaches no script under `--json`, as
  # a history and a preview are kept.
  @answered ~w(deployment image digest authority_digest state source failure)

  defp answered({:ok, %{status: 201, body: body}}, installation, application, env) do
    if is_map(body) and deployment?(body) do
      {:ok, body |> Map.take(@answered) |> Source.keeping()}
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
    source = Source.line(body["source"])

    Enum.join(
      [
        "Deployed #{Refusal.shown(application)} to #{Refusal.shown(env)}: deployment " <>
          "#{Refusal.shown(body["deployment"])} is #{Refusal.shown(body["state"])}.",
        "  image:            #{Refusal.shown(body["image"])}"
      ] ++
        if(source, do: ["  source:           #{source}"], else: []) ++
        [
          "  manifest digest:  #{Refusal.shown(body["digest"])}",
          "  authority digest: #{Refusal.shown(body["authority_digest"])}"
        ],
      "\n"
    )
  end

  ## Waiting

  # The deployment is printed as EHOS decided it, then each state it moves to as it is read, then
  # the outcome. Under `--json` nothing is printed until the outcome, in one document.
  defp follow(body, application, env, json?, opts) do
    installation = Keyword.fetch!(opts, :installation)
    wait_ms = Keyword.get(opts, :deploy_wait_ms, @wait_ms)
    say = if json?, do: fn _line -> :ok end, else: &IO.puts/1

    say.(deployed(body, application, env))
    say.("Waiting until it is active, for at most #{duration(wait_ms)}:")

    deadline = System.monotonic_time(:millisecond) + wait_ms
    where = {installation, application, env}
    pause = Keyword.get(opts, :deploy_poll_ms, @poll_ms)

    where
    |> wait(body["deployment"], nil, {deadline, pause}, say, opts)
    |> outcome(body, where, json?, wait_ms)
  end

  # `seen` is the deployment and the history last read, `nil` before one was.
  defp wait({installation, application, env} = where, id, seen, timing, say, opts) do
    read =
      with {:ok, history} <- Deployments.history(installation, application, env, opts),
           {:ok, deployment, history} <- found(history, id, where, opts),
           do: {:ok, deployment, history}

    case read do
      {:ok, deployment, history} ->
        if seen == nil or elem(seen, 0)["state"] != deployment["state"],
          do: say.("  " <> Refusal.shown(deployment["state"]))

        case moved(deployment) do
          :waiting ->
            again(where, id, {deployment, history}, timing, say, opts, fn ->
              {:waiting, deployment, history}
            end)

          moved ->
            {moved, deployment, history}
        end

      # A read EHOS did not answer, or answered that it could not now, is tried again until the
      # bound; a refusal is not, since EHOS records each read it refuses.
      {:error, :unreachable, _message} = error ->
        again(where, id, seen, timing, say, opts, fn ->
          if seen, do: Tuple.insert_at(seen, 0, :waiting), else: error
        end)

      other ->
        other
    end
  end

  # Reads further apart as the wait goes on: from `@poll_ms` growing by half each time, to
  # `@poll_max_ms`.
  # No pause runs past the bound, and no read starts after it.
  defp again(where, id, seen, {deadline, pause}, say, opts, ended) do
    left = deadline - System.monotonic_time(:millisecond)

    if left > 0 do
      Keyword.get(opts, :sleep, &Process.sleep/1).(min(pause, left))
    end

    if System.monotonic_time(:millisecond) >= deadline do
      ended.()
    else
      longer = min(div(pause * 3, 2), Keyword.get(opts, :deploy_poll_max_ms, @poll_max_ms))
      wait(where, id, seen, {deadline, max(longer, pause)}, say, opts)
    end
  end

  # The newest deployments are read, which hold the one just made unless more were decided after
  # it meanwhile: then as many as EHOS lists are read once, and if it is not among those either,
  # others have long since been decided after it.
  defp found(history, id, {installation, application, env}, opts) do
    case Deployments.find(history, id) do
      nil ->
        with {:ok, more} <-
               Deployments.history(installation, application, env, opts, @listed_most) do
          case Deployments.find(more, id) do
            nil -> {:displaced, id}
            deployment -> {:ok, deployment, more}
          end
        end

      deployment ->
        {:ok, deployment, history}
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

  defp outcome({:lacking, message}, body, {_installation, application, env}, json?, _wait_ms) do
    if json? do
      Output.result(%{text: "", json: Map.put(body, "outcome", "not_followed")}, true)
    else
      IO.puts(
        "ehosctl cannot follow it in #{Refusal.shown(env)}: #{message} Whether it became " <>
          "active is on #{Refusal.shown(application)}'s page in the console."
      )

      0
    end
  end

  defp outcome({:displaced, id}, body, {_installation, application, env}, json?, _wait_ms),
    do:
      ended(
        Map.put(body, "outcome", "displaced"),
        json?,
        :unreachable,
        "Deployment #{Refusal.shown(id)} is no longer among the newest deployments in " <>
          "#{Refusal.shown(env)}: others were decided after it, and one may have taken its " <>
          "place. `ehosctl apps show #{Refusal.shown(application)}` says what is in force there."
      )

  # A read that failed, or was refused, while waiting: the deployment stands, whatever came of it.
  defp outcome({:error, kind, message}, body, {_installation, app, _env}, _json?, _wait_ms),
    do: {:error, kind, message <> look(body["deployment"], app)}

  defp outcome(
         {moved, deployment, history},
         body,
         {_installation, application, env},
         json?,
         wait_ms
       ) do
    json =
      Map.merge(body, %{
        "state" => deployment["state"],
        "failure" => deployment["failure"],
        "outcome" => Atom.to_string(moved),
        "addresses" => history["addresses"]
      })

    id = Refusal.shown(deployment["id"])
    env = Refusal.shown(env)

    case moved do
      :active ->
        if json?,
          do: Output.result(%{text: "", json: json}, true),
          else:
            IO.puts(
              "Deployment #{id} is active in #{env}#{at(history["addresses"])}." <>
                later(history, deployment)
            )

        0

      :failed ->
        failure =
          if is_binary(deployment["failure"]),
            do: ": " <> Refusal.shown(deployment["failure"]),
            else: ", and EHOS gave no reason"

        ended(json, json?, :failed, "Deployment #{id} failed in #{env}#{failure}.")

      :superseded ->
        ended(
          json,
          json?,
          :failed,
          "Deployment #{id} was superseded in #{env}: #{replaced(history, deployment)} " <>
            "took its place."
        )

      # Its ephemeral environment was taken down while it rolled out (eh-os D-100), so it is not
      # in force, and never will be.
      :withdrawn ->
        ended(
          json,
          json?,
          :failed,
          "Deployment #{id} was withdrawn: #{env} was taken down while it rolled out."
        )

      :waiting ->
        ended(
          json,
          json?,
          :unreachable,
          "Deployment #{id} is still #{Refusal.shown(deployment["state"])} in #{env} after " <>
            "#{duration(wait_ms)}, and may yet become active or fail: " <>
            "`ehosctl apps show #{Refusal.shown(application)}` says its state later."
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
      " Deployment #{Refusal.shown(other)}, decided after it, is " <>
        "#{Refusal.shown(in_force["state"])} there."

  defp later(_history, _deployment), do: ""

  defp at([]), do: ""
  defp at(addresses), do: ", at " <> Enum.map_join(addresses, ", ", &Refusal.shown/1)

  defp look(id, application),
    do:
      " Deployment #{Refusal.shown(id)} was decided: " <>
        "`ehosctl apps show #{Refusal.shown(application)}` says its state."

  defp duration(ms) when ms >= 60_000 and rem(ms, 60_000) == 0,
    do: pluralized(div(ms, 60_000), "minute")

  defp duration(ms), do: pluralized(div(ms, 1_000), "second")

  defp pluralized(1, unit), do: "1 #{unit}"
  defp pluralized(count, unit), do: "#{count} #{unit}s"

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
