defmodule Ehosctl.InitServiceTest do
  # `ehosctl init --service NAME` (ehos-tools#917, eh-os D-175): ehos.yaml and the calling
  # workflow in a repository with no Elixir, then `ehosctl verify` there. Not async, through
  # `Ehosctl.SignInCase`: its `ehosctl/2` captures stderr, which every process shares.
  use Ehosctl.SignInCase

  alias Ehosctl.InitService

  doctest InitService

  # What eh-os's `EhosYaml.service_manifest/1` writes from the file `init` writes by default.
  @manifest ~s({"application":"invoice-pdf","ehos_yaml":"ehos.yaml/v8","health":{"live":"/live","port":8081,"ready":"/ready"},"kind":"service","needs":{"compute":{"memory":"256Mi"}},"schema":"ehos.manifest/v9","serves":[{"name":"http","port":8080}]})

  @tag_line "    uses: EmpoweredHouse/ehos-tools/.github/workflows/ehos-service.yml@" <>
              InitService.tag(Ehosctl.version())

  setup %{tmp_dir: tmp_dir, opts: opts} do
    service = Path.join(tmp_dir, "invoice-pdf")
    File.mkdir_p!(service)
    File.write!(Path.join(service, "Dockerfile"), "FROM scratch\n")
    %{service: service, opts: Keyword.put(opts, :dir, service)}
  end

  test "writes ehos.yaml and the pipeline into a repository with no Elixir, and verify passes " <>
         "there with the manifest EHOS writes",
       %{service: service, opts: opts} do
    assert {0, stdout, ""} = ehosctl(["init", "--service", "invoice-pdf"], opts)

    assert stdout =~ "ehosctl wrote ehos.yaml and .github/workflows/ehos.yml.\n"

    assert File.ls!(service) |> Enum.sort() == [".github", "Dockerfile", "ehos.yaml"]
    assert @tag_line in lines(service, ".github/workflows/ehos.yml")

    assert {0, _stdout, ""} = ehosctl(["verify"], opts)
    assert File.read!(Path.join(service, "_build/ehos.bundle/ehos.manifest.json")) == @manifest
  end

  test "says what EHOS asks of the image, writes no Dockerfile, and names the next step",
       %{service: service, opts: opts} do
    File.rm!(Path.join(service, "Dockerfile"))

    assert ehosctl(["init", "--service", "invoice-pdf", "--port", "9000"], opts) ==
             {0,
              """
              ehosctl wrote ehos.yaml and .github/workflows/ehos.yml.

              EHOS runs the image of the service as it is. Make sure that the image:
                - runs as a user that is not root,
                - listens on the ports in ehos.yaml, which start at 1024 (9000 and 8081 by the values given),
                - reads its settings from environment variables,
                - writes its logs to standard output.
              ehosctl writes no Dockerfile. Write one in this directory, in the language of the service.

              Run `ehosctl verify` to check ehos.yaml and write the bundle. .github/workflows/ehos.yml calls the shared workflow at #{InitService.tag(Ehosctl.version())}#{dev_note()}.
              """, ""}

    refute File.exists?(Path.join(service, "Dockerfile"))
  end

  test "writes each value given with its option", %{service: service, opts: opts} do
    {0, _stdout, ""} =
      ehosctl(
        ~w(init --service invoice-pdf --port 9000 --health-port 9001 --ready /up --live /ok --memory 1Gi),
        opts
      )

    {:ok, service} = Ehosctl.ServiceYaml.read(File.read!(Path.join(service, "ehos.yaml")))

    assert JSON.decode!(service.manifest) == %{
             "schema" => "ehos.manifest/v9",
             "ehos_yaml" => "ehos.yaml/v8",
             "kind" => "service",
             "application" => "invoice-pdf",
             "serves" => [%{"name" => "http", "port" => 9000}],
             "health" => %{"port" => 9001, "ready" => "/up", "live" => "/ok"},
             "needs" => %{"compute" => %{"memory" => "1Gi"}}
           }
  end

  test "asks at a terminal for each value not given, and takes the default for an empty answer",
       %{service: service, opts: opts} do
    answers =
      Agent.start_link(fn -> ["8000\n", "\n", "/healthy\n", "\n", "512Mi\n"] end) |> elem(1)

    stub(Ehosctl.TerminalMock, :input_terminal?, fn -> true end)
    stub(Ehosctl.TerminalMock, :error_terminal?, fn -> true end)

    stub(Ehosctl.TerminalMock, :gets, fn "" ->
      Agent.get_and_update(answers, fn [answer | rest] -> {answer, rest} end)
    end)

    assert {0, _stdout, stderr} = ehosctl(["init", "--service", "invoice-pdf"], opts)

    assert stderr ==
             "Port of the API [8080]: Port of the health check [8081]: Path that answers when " <>
               "the service is ready [/ready]: Path that answers while the service is alive " <>
               "[/live]: Memory the service needs [256Mi]: "

    {:ok, service} = Ehosctl.ServiceYaml.read(File.read!(Path.join(service, "ehos.yaml")))
    manifest = JSON.decode!(service.manifest)

    assert {manifest["serves"], manifest["health"], manifest["needs"]} ==
             {[%{"name" => "http", "port" => 8000}],
              %{"port" => 8081, "ready" => "/healthy", "live" => "/live"},
              %{"compute" => %{"memory" => "512Mi"}}}
  end

  test "a second run keeps each file and changes nothing", %{service: service, opts: opts} do
    {0, _stdout, ""} = ehosctl(["init", "--service", "invoice-pdf"], opts)
    File.write!(Path.join(service, "ehos.yaml"), "kept\n")
    workflow = File.read!(Path.join(service, ".github/workflows/ehos.yml"))

    assert {0, stdout, ""} = ehosctl(["init", "--service", "other", "--port", "9000"], opts)

    assert stdout =~
             "ehos.yaml and .github/workflows/ehos.yml existed already. ehosctl kept each as it " <>
               "is.\n"

    refute stdout =~ "ehosctl wrote"
    assert File.read!(Path.join(service, "ehos.yaml")) == "kept\n"
    assert File.read!(Path.join(service, ".github/workflows/ehos.yml")) == workflow
  end

  test "refuses values EHOS would refuse, with EHOS's reasons, and writes nothing",
       %{service: service, opts: opts} do
    assert ehosctl(["init", "--service", "Invoice_PDF", "--port", "80"], opts) ==
             {2, "",
              "ehosctl: ehosctl did not write ehos.yaml, because EHOS would refuse these values:\n" <>
                "  - NAME: must be lowercase letters, digits and dashes, starting " <>
                "with a letter and not ending with a dash, 63 characters at most\n" <>
                "  - --port: must be an integer from 1024 to 65535\n" <>
                "Give other values, with the options of each.\n"}

    assert File.ls!(service) == ["Dockerfile"]
  end

  test "refuses the directory of an application", %{service: service, opts: opts} do
    File.write!(Path.join(service, "mix.exs"), "")

    assert ehosctl(["init", "--service", "invoice-pdf"], opts) ==
             {2, "",
              "ehosctl: #{service} holds mix.exs, so it is the directory of an application. " <>
                "`ehosctl init --service` makes the repository of a utility service, which has " <>
                "no Elixir project. To make an application, run `ehosctl init NAME` without " <>
                "--service.\n"}

    refute File.exists?(Path.join(service, "ehos.yaml"))
  end

  defp lines(dir, path), do: dir |> Path.join(path) |> File.read!() |> String.split("\n")

  defp dev_note do
    if String.ends_with?(Ehosctl.version(), "-dev"),
      do:
        ", a release that this build of ehosctl comes before. The workflow runs once it is " <>
          "released",
      else: ""
  end
end
