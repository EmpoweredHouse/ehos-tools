defmodule Ehosctl.InitService do
  @moduledoc """
  `ehosctl init --service NAME`: the files EHOS needs in the repository of a utility service, a
  program with no contract and no Elixir project, in the current directory (eh-os
  [D-175](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0175-a-utility-service-is-an-application-with-no-contract-deployed-to-environments-as-any-other-and-another-application-reaches-it-only-once-the-service-s-side-agrees.md)).

  It writes two files, each only where none is:

    * `ehos.yaml`, `ehos.yaml/v8` with `kind: service`, the name in `application`, the port of the
      API, the port and paths of the health check, and the memory. A value not given with its
      option is asked at a terminal, and is the default elsewhere. The file is read back with
      `Ehosctl.ServiceYaml` before it is written, so a value EHOS would refuse is refused here with
      EHOS's reason.
    * `.github/workflows/ehos.yml`, a few lines that call ehos-tools' shared workflow
      `ehos-service.yml` at the tag of this `ehosctl`'s release, which installs the `ehosctl` of
      that tag ([T-27](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0027-a-utility-service-s-pipeline-is-a-workflow-of-ehos-tools-released-by-ehosctl-s-tag-which-installs-the-ehosctl-of-that-tag.md)).

  A file that exists is kept as it is and named, so a second run changes nothing the author owns.
  It writes no `Dockerfile`: the language is the author's. It says what EHOS asks of the image.
  A directory that holds `mix.exs` is an application's, and is refused.
  """

  alias Ehosctl.Refusal
  alias Ehosctl.ServiceYaml

  @ehos_yaml "ehos.yaml"
  @workflow ".github/workflows/ehos.yml"

  @defaults [port: 8080, health_port: 8081, ready: "/ready", live: "/live", memory: "256Mi"]

  @questions [
    port: "Port of the API",
    health_port: "Port of the health check",
    ready: "Path that answers when the service is ready",
    live: "Path that answers while the service is alive",
    memory: "Memory the service needs"
  ]

  @typedoc "The values of `ehos.yaml`, by the option that gives each."
  @type values :: %{
          port: integer() | String.t(),
          health_port: integer() | String.t(),
          ready: String.t(),
          live: String.t(),
          memory: String.t()
        }

  @doc """
  The options of `ehosctl init` that give the values of a utility service's `ehos.yaml`, in
  Optimus's form.
  """
  @spec options() :: keyword()
  def options do
    [
      port: [
        long: "--port",
        value_name: "PORT",
        parser: :integer,
        help: "With --service, the port of the API, from 1024. The default is 8080."
      ],
      health_port: [
        long: "--health-port",
        value_name: "PORT",
        parser: :integer,
        help: "With --service, the port of the health check, from 1024. The default is 8081."
      ],
      ready: [
        long: "--ready",
        value_name: "PATH",
        help:
          "With --service, the path that answers when the service is ready. The default is /ready."
      ],
      live: [
        long: "--live",
        value_name: "PATH",
        help:
          "With --service, the path that answers while the service is alive. The default is /live."
      ],
      memory: [
        long: "--memory",
        value_name: "MEMORY",
        help: "With --service, the memory the service needs, such as 512Mi. The default is 256Mi."
      ]
    ]
  end

  @doc """
  Writes the files of the utility service `name` into `opts[:dir]`, the current directory by
  default, from `given`, the options Optimus read, and returns what was written and kept.
  """
  @spec create(String.t(), map(), keyword()) :: Ehosctl.Command.result()
  def create(name, given, opts) do
    dir = Keyword.get_lazy(opts, :dir, &File.cwd!/0)

    with :ok <- not_an_application(dir),
         :ok <- no_link(dir),
         {:ok, ehos_yaml, values} <- ehos_yaml_file(dir, name, given) do
      [{@ehos_yaml, ehos_yaml}, {@workflow, workflow(name, Ehosctl.version())}]
      |> Enum.reduce_while({:ok, []}, &written(dir, &1, &2))
      |> said(values)
    end
  end

  # An `ehos.yaml` that is there is kept, and nothing is asked for it. The name is still checked
  # as EHOS checks it, with the defaults, since the workflow names it.
  defp ehos_yaml_file(dir, name, given),
    do: dir |> Path.join(@ehos_yaml) |> File.lstat() |> ehos_yaml_from(name, given)

  defp ehos_yaml_from({:ok, _there}, name, _given) do
    with {:ok, _ehos_yaml} <- checked(ehos_yaml(name, Map.new(@defaults))), do: {:ok, :kept, nil}
  end

  defp ehos_yaml_from({:error, _absent}, name, given) do
    values = values(given)
    with {:ok, ehos_yaml} <- checked(ehos_yaml(name, values)), do: {:ok, ehos_yaml, values}
  end

  @doc """
  The `ehos.yaml` of the utility service `name`, with `values`.

      iex> Ehosctl.InitService.ehos_yaml("invoice-pdf", %{port: 8080, health_port: 8081, ready: "/ready", live: "/live", memory: "256Mi"}) =~ ~s(application: "invoice-pdf")
      true
  """
  @spec ehos_yaml(String.t(), values()) :: String.t()
  def ehos_yaml(name, values) do
    """
    # What EHOS needs to run the utility service #{name}. A utility service has no
    # contract, and the applications of an environment share it. EHOS runs its image as it is:
    #   - as a user that is not root,
    #   - listening on ports from 1024,
    #   - with its settings in environment variables,
    #   - writing its logs to standard output.
    # `ehosctl verify` checks this file, and writes the bundle that the pipeline registers.
    schema: ehos.yaml/v8
    kind: service
    application: #{scalar(name)}
    # The port of the API that the applications of the environment call.
    serves:
      - name: http
        port: #{scalar(values.port)}
    # EHOS starts sending requests once the ready path answers 200, and restarts the service
    # when the live path stops answering.
    health:
      port: #{scalar(values.health_port)}
      ready: #{scalar(values.ready)}
      live: #{scalar(values.live)}
    needs:
      compute:
        memory: #{scalar(values.memory)}
    """
  end

  @doc """
  The workflow that calls ehos-tools' shared workflow for the utility service `name`, at the tag of
  the `ehosctl` release `version`: `v` and the version without `-dev`, so a build between releases
  names the release to come.
  """
  @spec workflow(String.t(), String.t()) :: String.t()
  def workflow(name, version) do
    """
    # The pipeline of the utility service #{name}. It calls the shared workflow of ehos-tools at
    # the tag of an ehosctl release, which installs the ehosctl of that release. To move to a later
    # pipeline, change the tag below to the tag of a later release, never to a branch: ehosctl
    # init writes this file once.
    #
    # The shared workflow builds the image for amd64 and arm64 and runs `ehosctl verify`. Once
    # the repository variable EHOSCTL_URL names the installation, it registers the build there,
    # from main and from a pull request of this repository that a person opened. If the
    # repository variable EHOS_PREVIEWS is true, it also deploys the build of such a pull request
    # to an ephemeral environment of its own. It removes that environment when a person closes the
    # pull request without a merge; otherwise the environment expires by itself.
    #
    # Repository variables: EHOSCTL_URL, the address of the installation; EHOSCTL_CA_PEM, its CA
    # when the installation uses a private one; EHOS_PREVIEWS. EHOS's trust of this repository
    # must name no workflow, because EHOS refuses a run of a workflow that this repository calls
    # from another repository under a trust that names one.
    # Secrets, while ehos-tools is private: EHOS_CI_APP_ID and EHOS_CI_APP_PRIVATE_KEY, of the
    # GitHub App that reads its releases.
    name: EHOS

    on:
      push:
        branches: [main]
      pull_request:
        types: [opened, synchronize, reopened, closed]

    # What the shared workflow's jobs need: to read the repository, to push the image to its
    # packages, a GitHub Actions token for EHOS, and to comment on a pull request.
    permissions:
      contents: read
      packages: write
      id-token: write
      pull-requests: write

    concurrency:
      group: ehos-${{ github.event.pull_request.number || github.ref }}
      cancel-in-progress: ${{ github.event_name == 'pull_request' && github.event.action != 'closed' }}

    jobs:
      ehos:
        uses: EmpoweredHouse/ehos-tools/.github/workflows/ehos-service.yml@#{tag(version)}
        secrets:
          EHOS_CI_APP_ID: ${{ secrets.EHOS_CI_APP_ID }}
          EHOS_CI_APP_PRIVATE_KEY: ${{ secrets.EHOS_CI_APP_PRIVATE_KEY }}
    """
  end

  @doc """
  The tag of the `ehosctl` release `version` names, the one its pipeline is called at.

      iex> Ehosctl.InitService.tag("0.41.0-dev")
      "v0.41.0"

      iex> Ehosctl.InitService.tag("0.41.0")
      "v0.41.0"
  """
  @spec tag(String.t()) :: String.t()
  def tag(version), do: "v" <> String.replace_suffix(version, "-dev", "")

  defp not_an_application(dir) do
    case File.lstat(Path.join(dir, "mix.exs")) do
      {:error, :enoent} ->
        :ok

      _there ->
        {:error, :invalid,
         "#{Refusal.shown(dir)} holds mix.exs, so it is the directory of an application. " <>
           "`ehosctl init --service` makes the repository of a utility service, which has no " <>
           "Elixir project. To make an application, run `ehosctl init NAME` without --service."}
    end
  end

  # Each value from its option, else asked where a person can answer, else the default.
  defp values(given) do
    terminal = Ehosctl.Terminal.current()
    ask? = terminal.input_terminal?() and terminal.error_terminal?()

    Map.new(@defaults, fn {key, default} ->
      {key, Map.get(given, key) || answer(ask?, terminal, key, default)}
    end)
  end

  defp answer(false, _terminal, _key, default), do: default

  defp answer(true, terminal, key, default) do
    IO.write(:stderr, "#{@questions[key]} [#{default}]: ")

    case terminal.gets("") do
      nil -> default
      typed -> typed |> String.trim() |> typed(default)
    end
  end

  defp typed("", default), do: default
  defp typed(text, default) when is_integer(default), do: integer(text)
  defp typed(text, _default), do: text

  # A port that is not a number is written as typed, for the schema to refuse with its reason.
  defp integer(text) do
    case Integer.parse(text) do
      {number, ""} -> number
      _other -> text
    end
  end

  # An integer as it is; anything else as a JSON string, which is a YAML scalar whatever it holds.
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(value), do: JSON.encode!(value)

  defp checked(ehos_yaml) do
    case ServiceYaml.read(ehos_yaml) do
      {:ok, _service} ->
        {:ok, ehos_yaml}

      {:error, reasons} ->
        {:error, :invalid,
         "Nothing is written: EHOS would refuse these values:\n" <>
           (reasons |> Enum.map(&by_option/1) |> ServiceYaml.listed()) <>
           "\nGive other values, with the options of each."}
    end
  end

  # A reason names the option that gave the value, since the file it is about was not written.
  @options %{
    "application" => "NAME",
    "serves[0].port" => "--port",
    "health.port" => "--health-port",
    "health.ready" => "--ready",
    "health.live" => "--live",
    "needs.compute.memory" => "--memory"
  }

  defp by_option(reason) do
    case Regex.run(~r/\Aline \d+, ([^:]+): (.*)\z/s, reason, capture: :all_but_first) do
      [path, message] -> "#{Map.get(@options, path, path)}: #{message}"
      nil -> reason
    end
  end

  # A file is written only into the repository: a link at `.github` or `.github/workflows` would
  # take it elsewhere, while ehosctl said it was written here.
  defp no_link(dir) do
    case Enum.find([".github", ".github/workflows"], &link?(Path.join(dir, &1))) do
      nil ->
        :ok

      link ->
        {:error, :invalid,
         "#{link} is a link. ehosctl writes no file through a link, so that each file stays in " <>
           "this repository. Make #{link} a directory, or remove it."}
    end
  end

  defp link?(path), do: match?({:ok, %{type: :symlink}}, File.lstat(path))

  defp written(_dir, {path, :kept}, {:ok, done}), do: {:cont, {:ok, [{:kept, path} | done]}}

  # `:exclusive`, so a file that is there, or a link put where one goes, is never written over.
  defp written(dir, {path, contents}, {:ok, done}) do
    full = Path.join(dir, path)

    with {:mkdir, :ok} <- {:mkdir, File.mkdir_p(Path.dirname(full))},
         {:write, :ok} <- {:write, File.write(full, contents, [:exclusive])} do
      {:cont, {:ok, [{:written, path} | done]}}
    else
      {:write, {:error, :eexist}} -> {:cont, {:ok, [{:kept, path} | done]}}
      {_step, {:error, reason}} -> {:halt, unwritable(path, reason, done)}
    end
  end

  defp unwritable(path, reason, done) do
    before = for {:written, written} <- done, do: written

    {:error, :failed,
     "#{path}: ehosctl cannot write it (#{:file.format_error(reason)})." <> before(before)}
  end

  defp before([]), do: ""
  defp before(paths), do: " ehosctl wrote #{Enum.join(paths, " and ")} before it."

  defp said({:ok, done}, values) do
    done = Enum.reverse(done)
    written = for {:written, path} <- done, do: path
    kept = for {:kept, path} <- done, do: path

    {:ok,
     %{
       text: wrote(written) <> kept(kept) <> image(values) <> next_steps(),
       json: %{written: written, kept: kept}
     }}
  end

  defp said(error, _values), do: error

  defp wrote([]), do: ""
  defp wrote(paths), do: "ehosctl wrote #{Enum.join(paths, " and ")}.\n"

  defp kept([]), do: ""

  defp kept(paths),
    do: "#{Enum.join(paths, " and ")} existed already. ehosctl kept each as it is.\n"

  defp image(values),
    do:
      "\nEHOS runs the image of the service as it is. Make sure that the image:\n" <>
        "  - runs as a user that is not root,\n" <>
        "  - listens on the ports in ehos.yaml, which start at 1024#{ports(values)},\n" <>
        "  - reads its settings from environment variables,\n" <>
        "  - writes its logs to standard output.\n" <>
        "ehosctl writes no Dockerfile. Write one in this directory, in the language of the " <>
        "service.\n"

  # The ports of a file ehosctl wrote; a file it kept says its own.
  defp ports(nil), do: ""
  defp ports(values), do: " (#{values.port} and #{values.health_port})"

  defp next_steps,
    do:
      "\nRun `ehosctl verify` to check ehos.yaml and write the bundle. " <>
        "#{@workflow} calls the shared workflow at #{tag(Ehosctl.version())}" <>
        released(Ehosctl.version()) <> "."

  defp released(version) do
    if String.ends_with?(version, "-dev"),
      do:
        ", a release that this build of ehosctl comes before. The workflow runs once it is released",
      else: ""
  end
end
