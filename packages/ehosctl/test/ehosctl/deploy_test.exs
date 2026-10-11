defmodule Ehosctl.DeployTest do
  use Ehosctl.SignInCase

  @digest String.duplicate("a1", 32)
  @image "ghcr.io/example/ledger@sha256:#{@digest}"
  # As it was generated: its spacing and key order are what EHOS digests.
  @manifest ~s({"schema": "ehos.manifest/v3",\n  "application": "ledger", "capabilities": []}\n)

  setup %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
    login!(provider, opts)
    file = Path.join(tmp_dir, "manifest.json")
    File.write!(file, @manifest)
    %{manifest: file}
  end

  defp deploy(file, extra \\ []),
    do: ["deploy", "ledger", "--env", "staging", "--image", @image, "--manifest", file | extra]

  defp deployment(state, failure \\ nil),
    do: %{
      "deployment" => "d-1",
      "image" => @image,
      "digest" => "sha256:" <> String.duplicate("b2", 32),
      "authority_digest" => "sha256:" <> String.duplicate("c3", 32),
      "state" => state,
      "failure" => failure
    }

  defp answer(provider, status, body),
    do: FakeProvider.stub_api(provider, "POST", "/api/v1/deployments", fn _ -> {status, body} end)

  test "sends the manifest as it is, with the environment and the image as parameters",
       %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 201, deployment("activating"))

    {0, stdout, ""} = ehosctl(deploy(file), opts)

    assert stdout =~ "Deployed ledger to staging: deployment d-1 is activating."
    assert stdout =~ "  image:            #{@image}"
    assert stdout =~ "  manifest digest:  sha256:b2b2"
    assert stdout =~ "Whether it became active is on the application's page in the console."

    assert [request] = FakeProvider.requests(provider, "POST /api/v1/deployments")
    assert request.body == @manifest
    assert request.content_type == "application/json"
    assert request.query == %{"environment" => "staging", "image" => @image}
  end

  test "--json prints EHOS's answer", %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 201, deployment("activating"))

    {0, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)
    assert JSON.decode!(stdout) == deployment("activating")
  end

  test "reads the manifest from stdin with -", %{provider: provider, opts: opts} do
    answer(provider, 201, deployment("activating"))

    {0, _stdout, ""} = ehosctl(deploy("-"), Keyword.put(opts, :stdin, @manifest))
    assert [%{body: @manifest}] = FakeProvider.requests(provider, "POST /api/v1/deployments")
  end

  # The device itself, read in latin1 so that each byte comes as it was sent, is tried with the
  # binary: ExUnit's StringIO cannot stand for a terminal's or a pipe's stdin in latin1.
  test "stdin's UTF-8 is sent as it came, and a manifest over 1 MiB is refused",
       %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 201, deployment("activating"))
    manifest = ~s({"application": "ledger", "label": "Zatwierdź wpis, café"})

    {0, _stdout, ""} = ehosctl(deploy("-"), Keyword.put(opts, :stdin, manifest))
    assert [%{body: ^manifest}] = FakeProvider.requests(provider, "POST /api/v1/deployments")

    File.write!(file, String.duplicate(" ", 1_048_577))

    assert {2, "",
            "ehosctl: #{file} is larger than 1048576 bytes, which is the most a manifest " <>
              "may be.\n"} == ehosctl(deploy(file), opts)

    big = ~s({"application": "ledger"}) <> String.duplicate(" ", 1_048_576)

    assert {2, "",
            "ehosctl: stdin is larger than 1048576 bytes, which is the most a manifest " <>
              "may be.\n"} == ehosctl(deploy("-"), Keyword.put(opts, :stdin, big))

    assert [_] = FakeProvider.requests(provider, "POST /api/v1/deployments")
  end

  test "a refused manifest lists its reasons", %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 422, %{
      "error" => "invalid",
      "message" => "The deployment was refused: the manifest is refused.",
      "reasons" => ["capabilities: is required", "roles\e[2J: unknown"]
    })

    assert {2, "", stderr} = ehosctl(deploy(file), opts)

    assert stderr ==
             "ehosctl: The deployment was refused: the manifest is refused.\n" <>
               "  - capabilities: is required\n" <> ~S(  - "roles\e[2J: unknown") <> "\n"
  end

  test "bytes that are not UTF-8 are refused, not changed, from stdin or a file",
       %{provider: provider, opts: opts, manifest: file} do
    manifest = ~s({"application": "ledger", "label": "\xFF"})

    assert {2, "", "ehosctl: stdin is not UTF-8, so it is not a manifest.\n"} ==
             ehosctl(deploy("-"), Keyword.put(opts, :stdin, manifest))

    File.write!(file, manifest)

    assert {2, "", "ehosctl: #{file} is not UTF-8, so it is not a manifest.\n"} ==
             ehosctl(deploy(file), opts)

    assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
  end

  @tag :unix
  test "a device that never ends is read only past the bound", %{opts: opts} do
    assert {2, "", "ehosctl: /dev/zero is larger than 1048576 bytes" <> _} =
             ehosctl(deploy("/dev/zero"), opts)
  end

  test "a gateway's 502 in JSON of its own says the deployment may have been decided",
       %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 502, %{"message" => "Internal server error"})

    assert {5, "", stderr} = ehosctl(deploy(file), opts)
    assert stderr =~ "It may have been deployed"
  end

  test "a gateway's 5xx says the deployment may have been decided",
       %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 504, %{})

    assert {5, "", stderr} = ehosctl(deploy(file), opts)
    assert stderr =~ "It may have been deployed: see ledger's page in the console for staging"
  end

  test "an application that is not text is said so", %{opts: opts, manifest: file} do
    File.write!(file, ~s({"application": {"name": "ledger"}}))

    assert {2, "", "ehosctl: #{file} names its application other than as text.\n"} ==
             ehosctl(deploy(file), opts)
  end

  test "a 201 that cannot be read still says the deployment was decided",
       %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 201, %{"deployment" => "d-1"})

    assert {1, "", stderr} = ehosctl(deploy(file), opts)
    assert stderr =~ "It answered 201, so the deployment was decided"
  end

  test "a manifest of another application, or none, is refused before anything is sent",
       %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 201, deployment("activating"))

    File.write!(file, ~s({"application": "journal"}))

    assert {2, "",
            "ehosctl: #{file} is the manifest of journal, not of ledger; nothing was sent.\n"} ==
             ehosctl(deploy(file), opts)

    File.write!(file, ~s({"schema": "ehos.manifest/v3"}))

    assert {2, "", "ehosctl: #{file} names no application, so it is not a manifest.\n"} ==
             ehosctl(deploy(file), opts)

    File.write!(file, "schema: ehos.manifest/v3")

    assert {2, "", "ehosctl: #{file} does not hold a JSON object, so it is not a manifest.\n"} ==
             ehosctl(deploy(file), opts)

    assert {2, "", "ehosctl: cannot read nothing.json: no such file or directory\n"} ==
             ehosctl(deploy("nothing.json"), opts)

    assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
  end

  test "--env, --image and --manifest are required", %{opts: opts} do
    assert {2, "", stderr} = ehosctl(["deploy", "ledger", "--image", @image], opts)
    assert stderr =~ "--env"
    assert stderr =~ "--manifest"
  end

  test "each refusal is the deploy page's sentence, and exits with its kind's code",
       %{provider: provider, opts: opts, manifest: file} do
    cases = [
      {403, "forbidden",
       "Deploying this application to staging needs ehos.application.deploy for it there, and " <>
         "ehos.application.register as well for a manifest that puts another authority in force.",
       3},
      {404, "not_found", "staging was removed meanwhile.", 1},
      {409, "database_kept",
       "The deployment was refused: the application's database there is kept, and the " <>
         "manifest drops it.", 1},
      {409, "unbound", "The deployment was refused: a need cannot be bound.", 1},
      {409, "binding_moved", "The deployment was refused: a binding moved meanwhile.", 1},
      {413, "too_large", "The document is larger than 1048576 bytes.", 2},
      {422, "invalid_image",
       "Name the image by digest: <registry>[:<port>]/<repository>@sha256:<64 hexadecimal " <>
         "digits>, in lowercase ASCII.", 2},
      {422, "invalid", "The deployment was refused: the manifest is an ehos.manifest/v1.", 2}
    ]

    for {status, code, sentence, exit_code} <- cases do
      answer(provider, status, %{"error" => code, "message" => sentence})

      assert {^exit_code, "", stderr} = ehosctl(deploy(file), opts)
      assert stderr == "ehosctl: #{sentence}\n", code
    end
  end

  test "a deployment the cluster did not take names itself and its failure",
       %{provider: provider, opts: opts, manifest: file} do
    sentence =
      "The deployment was decided, but the cluster did not take its objects, so it failed. " <>
        "Its failure says what the cluster answered."

    answer(
      provider,
      502,
      Map.merge(deployment("failed", "admission webhook denied the Deployment"), %{
        "error" => "cluster_refused",
        "message" => sentence
      })
    )

    assert {5, "", stderr} = ehosctl(deploy(file), opts)

    assert stderr ==
             "ehosctl: #{sentence} Deployment d-1. Its failure: admission webhook denied the " <>
               "Deployment.\n"

    superseded =
      "A later deployment of the application there was decided first, so this one was not " <>
        "written."

    answer(
      provider,
      409,
      Map.merge(deployment("superseded"), %{"error" => "superseded", "message" => superseded})
    )

    assert {1, "", "ehosctl: #{superseded} Deployment d-1.\n"} == ehosctl(deploy(file), opts)
  end
end
