defmodule Ehosctl.Deploy do
  @moduledoc """
  `ehosctl deploy <application> --env E --image <repository>@sha256:… --manifest <file>`: deploys
  an image, by digest, with its application manifest, to an environment, as the console's deploy
  page does (eh-os D-52, D-53,
  [`docs/manifest.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/manifest.md#deploying-with-one)).

  It sends `POST /api/deployments?environment=E&image=…` with the manifest as its body, the bytes
  of the file as they are, since EHOS keeps and digests the manifest as it was sent. The manifest
  must be for `<application>`, or nothing is sent: the name on the command line is what the person
  meant to deploy, and a manifest of another application would deploy that one.

  It needs `ehos.application.deploy` in the environment, and `ehos.application.register` too when
  the manifest puts another authority in force. A refusal is printed in the deploy page's words.

  EHOS answers once the cluster has the deployment's objects, while it is `activating`; whether
  it became active is on the application's page in the console, since the API does not say yet.
  """

  @behaviour Ehosctl.Command

  alias Ehosctl.Api
  alias Ehosctl.Output
  alias Ehosctl.Refusal

  @impl Ehosctl.Command
  def name, do: :deploy

  @impl Ehosctl.Command
  def plane, do: :governed

  @impl Ehosctl.Command
  def spec,
    do: [
      about: "Deploy an image, by digest, with its manifest, to an environment.",
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
          required: true,
          help: "The image, by digest: <registry>/<repository>@sha256:<digest>."
        ],
        manifest: [
          long: "--manifest",
          value_name: "FILE",
          required: true,
          help: "The application manifest, its JSON file as it was generated; - for stdin."
        ]
      ],
      flags: Output.json_flag()
    ]

  @impl Ehosctl.Command
  @spec call([atom()], Optimus.ParseResult.t(), keyword()) :: Ehosctl.Command.result()
  def call([], parsed, opts) do
    installation = Keyword.fetch!(opts, :installation)
    application = parsed.args.application
    %{env: env, image: image, manifest: file} = parsed.options

    with {:ok, manifest} <- manifest(file, opts),
         :ok <- for_application(manifest, file, application) do
      path = "/api/deployments?" <> URI.encode_query(environment: env, image: image)

      installation
      |> Api.answer(:post, path, {:raw, "application/json", manifest}, opts)
      |> answered(installation, application, env)
    end
  end

  # EHOS takes a manifest of at most 1 MiB; a larger one is refused before it is read whole.
  @max_bytes 1_048_576

  # stdin is in unicode mode (`Ehosctl.Application`), which hands UTF-8, as JSON is, on as it
  # came; a read in bytes would ask it for latin1 instead.
  defp manifest("-", opts) do
    case Keyword.get_lazy(opts, :stdin, fn -> IO.read(:stdio, @max_bytes + 1) end) do
      text when is_binary(text) -> sized(text, "stdin")
      :eof -> {:ok, ""}
      {:error, _reason} -> {:error, :invalid, "stdin could not be read as UTF-8 text."}
    end
  end

  defp manifest(file, _opts) do
    with {:ok, %File.Stat{size: size}} <- File.stat(file),
         :ok <- if(size > @max_bytes, do: {:error, :too_large}, else: :ok),
         {:ok, bytes} <- File.read(file) do
      sized(bytes, file)
    else
      {:error, :too_large} ->
        too_large(file)

      {:error, reason} ->
        {:error, :invalid, "cannot read #{shown_path(file)}: #{:file.format_error(reason)}"}
    end
  end

  defp sized(bytes, where) when byte_size(bytes) > @max_bytes, do: too_large(where)
  defp sized(bytes, _where), do: {:ok, bytes}

  defp too_large(where),
    do:
      {:error, :invalid,
       "#{shown_path(where)} is larger than #{@max_bytes} bytes, which is the most a manifest may be."}

  defp shown_path(path), do: Refusal.shown(path)

  defp for_application(manifest, file, application) do
    where = if file == "-", do: "stdin", else: shown_path(file)

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
  defp answered({:ok, %{status: status, body: %{} = body} = answer}, installation, _app, _env)
       when status in [409, 502] do
    {:error, kind, message} = Api.refusal(answer, installation)

    case body do
      %{"deployment" => id} when is_binary(id) ->
        failure =
          if is_binary(body["failure"]), do: " Its failure: #{Refusal.shown(body["failure"])}."

        {:error, kind, "#{message} Deployment #{Refusal.shown(id)}.#{failure}"}

      _body ->
        {:error, kind, message}
    end
  end

  # A refused manifest's reasons, each naming a field, under the sentence, which says only that it
  # was refused.
  defp answered(
         {:ok, %{status: 422, body: %{"reasons" => [_ | _] = reasons}} = answer},
         installation,
         _application,
         _env
       ) do
    {:error, kind, message} = Api.refusal(answer, installation)
    lines = for reason <- reasons, is_binary(reason), do: "\n  - " <> Refusal.shown(reason)
    {:error, kind, Enum.join([message | lines])}
  end

  # A 5xx with no code of EHOS's own, such as a gateway's timeout, may have come after the
  # deployment was decided.
  defp answered({:ok, %{status: status} = answer}, installation, application, env)
       when status >= 500 do
    {:error, kind, message} = Api.refusal(answer, installation)

    if is_map(answer.body) and is_binary(answer.body["error"]),
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
end
