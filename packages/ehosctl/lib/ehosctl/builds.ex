defmodule Ehosctl.Builds do
  @moduledoc """
  `ehosctl builds register | list | openapi`: an application's builds, each an image by its digest with the
  bundle written beside it, registered by its CI with the commit it came from, so EHOS knows each
  version before anyone deploys it (eh-os
  [D-146](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0146-a-build-is-a-record-of-its-own-registered-by-ci-with-the-commit-it-came-from-a-deployment-names-a-build-and-a-promotion-s-review-links-to-what-changed.md),
  [`docs/builds-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/builds-api.md)),
  as the application's Builds tab in the console shows them. `ehosctl deploy --build` deploys one.

  `register <dir> --image <repository>@sha256:…` reads the bundle in `dir`, as
  `mix eh_os_contract.bundle --output-dir` writes it, each file checked against its `bundle.json`
  (`Ehosctl.Bundle`), and sends `POST /api/v1/applications/:name/builds` for the application its
  manifest names: a `multipart/form-data` body of the parts `build` (JSON: `image` and what is
  stated of it), `bundle`, `manifest`, then `graph` for each document in `bundle.json`'s order,
  and last `openapi`, a utility service's OpenAPI file, when an `ehos.bundle/v2` names one.
  In a GitHub Actions job it states what it reads of the checkout and of the event
  (`Ehosctl.Checkout`), and EHOS takes the repository, ref, commit and run from the job's token;
  elsewhere it states nothing, and the build is the person's who registered it, deployed by its id
  alone. It needs a pipeline's credential, or `ehos.application.deploy` on the application. The
  same run attempt registering the same bundle again gets the build it registered; another bundle
  from it is refused. EHOS takes at most 60 registrations of an application a minute.

  `list <application> [--ref <ref>] [--limit <n>]` reads `GET /api/v1/applications/:name/builds`,
  newest first, at most 50 unless `--limit` says another number up to 200, and with `--ref` only
  those GitHub's token named that ref for, given in full (`refs/heads/main`). It needs
  `ehos.application.deploy`, `ehos.application.register` or `ehos.release.approve` in the
  application; a pipeline reads none. Each build is printed with its id, when it was registered,
  its ref and commit, and the title stated of it; under `--json`, kept to the fields `ehosctl`
  reads.

  `openapi <service> <build> [--output <file>]` downloads the OpenAPI file of a utility service's
  build, `GET /api/v1/applications/:name/builds/:id/openapi` (eh-os D-175), as it came, at most
  1 MiB, into the file EHOS names, `<service>-openapi.<extension>`, or `--output`, in the current
  directory. It writes over no file. It needs what `list` needs. The route answers the file, not
  JSON, so it is read as bytes (`c:Ehosctl.HTTP.get/3`), asking for any type: EHOS's API refuses
  a request that asks only for the file's own.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Bundle
  alias Ehosctl.Checkout
  alias Ehosctl.Credentials
  alias Ehosctl.Failure
  alias Ehosctl.ManifestFile
  alias Ehosctl.Multipart
  alias Ehosctl.Output
  alias Ehosctl.Refusal
  alias Ehosctl.Source
  alias EhosPlatform.Shell

  require Ehosctl.Api

  @image ~r/\A[^@\s]+@sha256:[0-9a-f]{64}\z/
  @most_listed 200
  @title_shown 60
  # The name EHOS gives the file: the service's, then the name the bundle gave it.
  @openapi_file ~r/\A[a-z]([a-z0-9-]*[a-z0-9])?-openapi\.(json|yaml|yml)\z/

  @impl Ehosctl.Command
  def name, do: :builds

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def group, do: :applications

  @impl Ehosctl.Command
  def summary, do: "Register and list the builds of an application."

  @impl Ehosctl.Command
  def spec,
    do: [
      about:
        "Register and list the builds of an application. A build is an image by digest and " <>
          "the bundle written beside it.",
      subcommands: [
        register: [
          name: "register",
          about:
            "Register the image and the bundle in DIR as a build of the application that the " <>
              "application manifest names. In a GitHub Actions job, also state what the checkout says of " <>
              "the commit.",
          args: [
            dir: [
              value_name: "DIR",
              required: true,
              help:
                "The directory of the bundle, as `mix eh_os_contract.bundle --output-dir` " <>
                  "writes it."
            ]
          ],
          options: [
            image: [
              long: "--image",
              value_name: "IMAGE",
              required: true,
              help: "The image, by digest: <registry>/<repository>@sha256:<digest>."
            ]
          ],
          flags: Output.json_flag()
        ],
        list: [
          name: "list",
          about: "List the builds of an application, newest first.",
          args: [
            application: [
              value_name: "APPLICATION",
              required: true,
              help: "The name of the application."
            ]
          ],
          options: [
            ref: [
              long: "--ref",
              value_name: "REF",
              help:
                "Show only the builds of this full ref, as GitHub names it, such as " <>
                  "refs/heads/main or refs/pull/42/merge."
            ],
            limit: [
              long: "--limit",
              value_name: "N",
              parser: :integer,
              help: "The most builds to show, from 1 to #{@most_listed}. The default is 50."
            ]
          ],
          flags: Output.json_flag()
        ],
        openapi: [
          name: "openapi",
          about:
            "Download the OpenAPI file of a build of a utility service, as the bundle held it. " <>
              "ehosctl writes over no file.",
          args: [
            application: [
              value_name: "SERVICE",
              required: true,
              help: "The name of the utility service."
            ],
            build: [
              value_name: "BUILD",
              required: true,
              help: "The id of the build, as `ehosctl builds list` shows it."
            ]
          ],
          options: [
            output: [
              long: "--output",
              value_name: "FILE",
              help:
                "The file to write. The default is the name EHOS gives the file, such as " <>
                  "invoice-pdf-openapi.yaml, in the current directory."
            ]
          ],
          flags: Output.json_flag()
        ]
      ]
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([:openapi], %{args: %{application: app}}, _opts) when Api.is_nameless(app),
    do: {:error, :invalid, "#{inspect(app)} is not the name of a utility service."}

  def call([:openapi], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    %{application: app, build: build} = parsed.args

    with :ok <- build_id(build),
         {:ok, bytes, headers} <- openapi(installation, app, build, opts),
         {:ok, file} <- openapi_file(parsed.options.output, headers, app),
         :ok <- saved(Path.expand(file, Keyword.get_lazy(opts, :dir, &File.cwd!/0)), file, bytes) do
      {:ok,
       %{
         text:
           "Wrote #{Refusal.shown(file)}, the OpenAPI file of build #{build} of " <>
             "#{Refusal.shown(app)}, #{byte_size(bytes)} bytes, as the bundle held it.",
         json: %{application: app, build: build, file: file, bytes: byte_size(bytes)}
       }}
    end
  end

  def call([:list], %{args: %{application: app}}, _opts) when Api.is_nameless(app),
    do: {:error, :invalid, "#{inspect(app)} is not the name of an application."}

  def call([:list], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    app = parsed.args.application
    %{ref: ref, limit: limit} = parsed.options

    with :ok <- limit(limit),
         query = Enum.reject([ref: ref, limit: limit], &is_nil(elem(&1, 1))),
         {:ok, %{"builds" => builds}} when is_list(builds) <-
           Api.read(installation, path(app) <> query(query), opts),
         true <- Enum.all?(builds, &build?/1) || Api.unexpected(installation) do
      builds = Enum.map(builds, &kept/1)
      {:ok, %{text: listed(app, ref, builds), json: %{application: app, builds: builds}}}
    else
      {:ok, _body} -> Api.unexpected(installation)
      error -> error
    end
  end

  def call([:register], parsed, opts) do
    dir = parsed.args.dir
    image = parsed.options.image
    env = Ehosctl.SystemEnv.current().all()

    with :ok <- image(image),
         {:ok, bundle} <- Bundle.read(dir) do
      app = bundle.application
      stated = Checkout.stated(env, Keyword.get_lazy(opts, :dir, &File.cwd!/0))

      build =
        JSON.encode!(Map.reject(%{"image" => image, "stated" => stated}, &(elem(&1, 1) == %{})))

      body =
        Multipart.body(
          [{"build", build}, {"bundle", bundle.index}, {"manifest", bundle.manifest}] ++
            Enum.map(bundle.graphs, &{"graph", &1}) ++ openapi_part(bundle.openapi)
        )

      # A job's exchange names the application whose trust is meant (T-18).
      opts = Keyword.put(opts, :application, app)

      opts
      |> Keyword.fetch!(:installation)
      |> Api.answer(:post, path(app), body, opts)
      |> registered(opts, app, stated)
      |> openapi_taken(bundle.openapi, opts)
    end
  end

  # An EHOS before it took a utility service's OpenAPI file refuses the part with words of its
  # own. Its routes say whether it is one, and if so, the refusal says what to do.
  defp openapi_taken({:error, :invalid, _message, _refusal} = refused, %{}, opts),
    do: Refusal.added(refused, openapi_lacking(opts))

  defp openapi_taken({:error, :invalid, _message} = refused, %{}, opts),
    do: Refusal.added(refused, openapi_lacking(opts))

  defp openapi_taken(result, _openapi, _opts), do: result

  @openapi_route "/api/v1/applications/service/builds/00000000-0000-0000-0000-000000000000/openapi"

  defp openapi_lacking(opts) do
    {_name, installation} = named = Keyword.fetch!(opts, :installation)

    case Api.describe(named, opts) do
      {:ok, %{"routes" => routes} = described} -> openapi_advice(routes, installation, described)
      _unknown -> ""
    end
  end

  defp openapi_advice(routes, installation, described) do
    if Api.route?(routes, "GET", @openapi_route),
      do: "",
      else:
        " #{Refusal.shown(installation["url"])} runs EHOS #{Api.running(described)}, which " <>
          "takes no OpenAPI file with a build. Until the operator upgrades EHOS, remove the " <>
          "OpenAPI file from the directory of the service and run `ehosctl verify` again."
  end

  # eh-os D-175: a utility service's OpenAPI file goes last, as its bundle names it, as it is.
  defp openapi_part(nil), do: []
  defp openapi_part(%{bytes: bytes}), do: [{"openapi", bytes, "application/octet-stream"}]

  defp path(app), do: "/api/v1/applications/#{Api.segment(app)}/builds"

  defp build_id(build) do
    if Api.uuid?(build),
      do: :ok,
      else:
        {:error, :invalid,
         "#{Refusal.shown(build)} is not the id of a build. `ehosctl builds list SERVICE` shows " <>
           "the ids."}
  end

  defp openapi(installation, app, build, opts) do
    path = path(app) <> "/" <> Api.segment(build) <> "/openapi"
    url = elem(installation, 1)["url"] <> path

    with {:ok, credential} <- Credentials.fetch(installation, :ehos, opts),
         {:ok, answer} <-
           Ehosctl.HTTP.current().get(
             url,
             [{"authorization", "Bearer " <> credential}, {"accept", "*/*"}],
             Keyword.put(opts, :max_bytes, ManifestFile.max_bytes())
           ) do
      openapi_answer(answer, installation, path, opts)
    end
  end

  defp openapi_answer(%{status: 200, body: bytes, headers: headers}, _installation, _path, _opts)
       when byte_size(bytes) > 0,
       do: {:ok, bytes, headers}

  # A refusal is JSON, read as `Ehosctl.Api` reads one, and a route an older EHOS lacks is said so.
  defp openapi_answer(answer, installation, path, opts) do
    decoded = %{answer | body: decoded(answer.body)}

    case Api.routed_answer(installation, :get, path, decoded, opts) do
      {:ok, refused} -> Api.refusal(refused, installation)
      {:lacking, message} -> {:error, :failed, message}
    end
  end

  defp decoded(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  defp openapi_file(output, _headers, _app) when is_binary(output), do: {:ok, output}

  defp openapi_file(nil, headers, app) do
    case Regex.run(~r/filename="([^"]*)"/, headers["content-disposition"] || "") do
      [_, file] -> named_file(file, app)
      nil -> unnamed()
    end
  end

  # The service's own name, then the name the bundle gave the file: never a path.
  defp named_file(file, app) do
    if Regex.match?(@openapi_file, file) and String.starts_with?(file, app <> "-openapi."),
      do: {:ok, file},
      else: unnamed()
  end

  defp unnamed,
    do:
      {:error, :failed,
       "EHOS did not name the OpenAPI file as ehosctl expects. Give the file to write with " <>
         "--output FILE."}

  # `:exclusive`, so no file is written over, and no link put where the file goes is written through.
  defp saved(path, file, bytes) do
    case File.write(path, bytes, [:exclusive]) do
      :ok ->
        :ok

      {:error, :eexist} ->
        {:error, :invalid,
         "#{Refusal.shown(file)} exists. ehosctl writes over no file. Remove it, or give " <>
           "another file with --output FILE."}

      {:error, reason} ->
        {:error, :failed,
         "#{Refusal.shown(file)}: ehosctl cannot write it (#{:file.format_error(reason)})."}
    end
  end

  defp query([]), do: ""
  defp query(query), do: "?" <> URI.encode_query(query)

  defp limit(nil), do: :ok
  defp limit(limit) when limit in 1..@most_listed, do: :ok

  defp limit(_limit),
    do: {:error, :invalid, "--limit must be a number of builds from 1 to #{@most_listed}."}

  # EHOS refuses an image not pinned by digest (`invalid_image`): it is refused here first.
  defp image(image) do
    if Regex.match?(@image, image),
      do: :ok,
      else:
        {:error, :invalid,
         "--image #{Refusal.shown(image)} is not pinned by digest. Give it as " <>
           "<registry>/<repository>@sha256:<64 hexadecimal digits>. ehosctl sent nothing."}
  end

  ## Registering

  defp registered({:ok, %{status: status, body: %{"build" => build}}}, opts, app, stated)
       when status in [200, 201] do
    installation = Keyword.fetch!(opts, :installation)

    if build?(build) do
      build = kept(build)
      {:ok, %{text: registration(status, build, app, stated), json: %{build: build}}}
    else
      {:error, kind, message} = Api.unexpected(installation)

      {:error, kind,
       Failure.added(message, " EHOS answered that it registered the build." <> look(app))}
    end
  end

  defp registered({:ok, %{status: 422} = answer}, opts, _app, _stated),
    do: ManifestFile.refused(answer, Keyword.fetch!(opts, :installation))

  defp registered({:ok, %{status: 429} = answer}, opts, _app, _stated) do
    later =
      case Integer.parse(Map.get(answer.headers, "retry-after", "")) do
        {seconds, ""} when seconds > 0 -> " Try again in #{seconds} seconds."
        _none -> ""
      end

    answer |> Api.refusal(Keyword.fetch!(opts, :installation)) |> Refusal.added(later)
  end

  defp registered({:ok, %{status: status} = answer}, opts, app, _stated) do
    refused = Api.refusal(answer, Keyword.fetch!(opts, :installation))

    # A 5xx with no code of EHOS's own, such as a gateway's, may have come after it was kept.
    if status >= 500 and not Api.coded?(answer.body),
      do: Refusal.added(refused, " EHOS may have registered the build." <> look(app)),
      else: refused
  end

  defp registered({:error, kind, message, :sent}, _opts, app, _stated),
    do:
      {:error, kind, Failure.added(message, " EHOS may have registered the build." <> look(app))}

  defp registered(error, _opts, _app, _stated), do: error

  defp look(app),
    do:
      Output.offered(
        " Run `ehosctl builds list #{Shell.word(app)}` to see the builds of the application."
      )

  defp registration(status, build, app, stated) do
    said =
      if status == 201,
        do: "Registered build #{Refusal.shown(build["id"])} of #{Refusal.shown(app)}.",
        else:
          "This run registered build #{Refusal.shown(build["id"])} of #{Refusal.shown(app)} " <>
            "before, with this image and bundle."

    Enum.join(
      [said, "  image:  #{Refusal.shown(build["image"])}"] ++
        from(build) ++
        ["  stated: #{stated_line(stated)}"] ++
        [
          Output.offered(
            "Deploy it with `ehosctl deploy #{Shell.word(app)} --env ENVIRONMENT --build " <>
              "#{Shell.word(build["id"])}`."
          )
        ],
      "\n"
    )
    |> String.trim_trailing("\n")
  end

  defp from(build) do
    case Source.line(build["source"]) do
      nil -> []
      line -> ["  source: #{line}"]
    end
  end

  defp stated_line(stated) when stated == %{}, do: "nothing"

  defp stated_line(stated) do
    [
      stated["title"] && "the commit's title",
      stated["author"] && "its author",
      stated["committed_at"] && "its time",
      stated["pull_request"] &&
        "pull request #{if n = stated["pull_request"]["number"], do: "##{n}", else: "details"}",
      stated["commits"] && commits(length(stated["commits"]))
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
  end

  defp commits(1), do: "1 commit before it"
  defp commits(n), do: "#{n} commits before it"

  ## Listing

  @doc """
  Whether `build` is a build as EHOS gives it, its fields each of its type or null: what is
  printed of it reads nothing else. A refusal at a count of ephemeral environments names builds of
  the same shape (`Ehosctl.AtCount`).
  """
  @spec build?(term()) :: boolean()
  def build?(%{"id" => id, "image" => image, "registered_at" => at} = build)
      when is_binary(id) and is_binary(image) and is_binary(at),
      do:
        Enum.all?(
          ~w(image_digest manifest_digest bundle_digest ref registered_by),
          &text_or_nil?(build[&1])
        ) and map_or_nil?(build["source"]) and map_or_nil?(build["stated"])

  def build?(_build), do: false

  @kept ~w(id image image_digest manifest_digest bundle_digest ref source stated registered_at registered_by)
  @stated ~w(commit ref title author committed_at)

  @doc """
  A build that `build?/1` takes, kept to the fields `ehosctl` reads, each of its type, so nothing
  else an answer holds reaches a script under `--json` or a terminal: the source as a deployment's
  is kept (`Ehosctl.Source.kept/1`), which `Source.line/1` relies on, with the build's own fields,
  and what is stated to its fields.
  """
  @spec kept(map()) :: map()
  def kept(build) do
    build
    |> Map.take(@kept)
    |> Map.update("source", nil, &source/1)
    |> Map.update("stated", nil, &stated/1)
  end

  # A build's run names its repository's id and its workflow too, beside what a deployment's does.
  defp source(source) do
    case Source.kept(source) do
      %{"kind" => "github_run"} = kept ->
        named =
          for {key, value} <- Map.take(source, ~w(repository_id workflow)),
              (key == "repository_id" and is_integer(value)) or
                (key == "workflow" and is_binary(value)),
              into: %{},
              do: {key, value}

        Map.merge(kept, named)

      other ->
        other
    end
  end

  defp stated(%{} = stated) do
    texts =
      for {key, value} <- Map.take(stated, @stated), is_binary(value), into: %{}, do: {key, value}

    texts
    |> put_kept("pull_request", pull_request(stated["pull_request"]))
    |> put_kept("commits", stated_commits(stated["commits"]))
  end

  defp stated(_stated), do: nil

  defp pull_request(%{} = pull_request) do
    kept =
      for {key, value} <- Map.take(pull_request, ~w(number head title)),
          (key == "number" and is_integer(value)) or (key != "number" and is_binary(value)),
          into: %{},
          do: {key, value}

    if kept != %{}, do: kept
  end

  defp pull_request(_pull_request), do: nil

  defp stated_commits(commits) when is_list(commits) do
    for %{"commit" => commit, "title" => title} <- commits,
        is_binary(commit) and is_binary(title),
        do: %{"commit" => commit, "title" => title}
  end

  defp stated_commits(_commits), do: nil

  defp put_kept(map, _key, nil), do: map
  defp put_kept(map, key, value), do: Map.put(map, key, value)

  defp listed(app, ref, []),
    do:
      "No builds of #{Refusal.shown(app)}#{on(ref)}. A build shows here when the pipeline of " <>
        "the application, or a person, runs `ehosctl builds register`."

  defp listed(app, ref, builds) do
    rows =
      Enum.map(builds, fn build ->
        %{
          "BUILD" => Refusal.shown(build["id"]),
          "REGISTERED" => Output.date(build["registered_at"]),
          "REF" => ref_of(build),
          "COMMIT" => commit_of(build),
          "TITLE" => title_of(build)
        }
      end)

    Enum.join(
      [
        "Builds of #{Refusal.shown(app)}#{on(ref)}, newest first:",
        Output.table(rows, ["BUILD", "REGISTERED", "REF", "COMMIT", "TITLE"]),
        Output.offered(
          "Deploy one with `ehosctl deploy #{Shell.word(app)} --env ENVIRONMENT --build BUILD`."
        )
      ],
      "\n"
    )
    |> String.trim_trailing("\n")
  end

  defp on(nil), do: ""
  defp on(ref), do: " on #{Refusal.shown(ref)}"

  # GitHub's token's, else what a person stated, said to be stated.
  defp ref_of(%{"ref" => ref}) when is_binary(ref), do: Refusal.shown(ref)

  defp ref_of(%{"stated" => %{"ref" => ref}}) when is_binary(ref),
    do: Refusal.shown(ref) <> " (stated)"

  defp ref_of(_build), do: Output.none()

  defp commit_of(%{"source" => %{"commit" => commit}}) when is_binary(commit),
    do: Refusal.shown(String.slice(commit, 0, 12))

  defp commit_of(%{"stated" => %{"commit" => commit}}) when is_binary(commit),
    do: Refusal.shown(String.slice(commit, 0, 12)) <> " (stated)"

  defp commit_of(_build), do: Output.none()

  defp title_of(%{"stated" => %{"title" => title}}) when is_binary(title) do
    if String.length(title) > @title_shown,
      do: Refusal.shown(String.slice(title, 0, @title_shown - 1)) <> "…",
      else: Refusal.shown(title)
  end

  defp title_of(_build), do: Output.none()

  defp text_or_nil?(value), do: is_nil(value) or is_binary(value)
  defp map_or_nil?(value), do: is_nil(value) or is_map(value)
end
