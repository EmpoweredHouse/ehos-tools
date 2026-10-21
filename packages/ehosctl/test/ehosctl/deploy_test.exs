defmodule Ehosctl.DeployTest do
  use Ehosctl.SignInCase

  doctest Ehosctl.Review

  @digest String.duplicate("a1", 32)
  @image "ghcr.io/example/ledger@sha256:#{@digest}"
  # As it was generated: its spacing and key order are what EHOS digests.
  @manifest ~s({"schema": "ehos.manifest/v3",\n  "application": "ledger", "capabilities": []}\n)

  @deployments "/api/v1/applications/ledger/environments/staging/deployments"
  @address "https://ledger.staging.example.com"

  setup %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
    login!(provider, opts)
    file = Path.join(tmp_dir, "manifest.json")
    File.write!(file, @manifest)

    # Unless a test says otherwise, the deployment is active at the first read, read without a pause.
    history(provider, [listed(listing("d-1", "active"))])
    %{manifest: file, opts: Keyword.put(opts, :deploy_poll_ms, 0)}
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

  # A deployment as the application's deployments list it.
  defp listing(id, state, failure \\ nil),
    do: %{
      "kind" => "deployment",
      "id" => id,
      "state" => state,
      "image" => @image,
      "manifest_digest" => "sha256:" <> String.duplicate("b2", 32),
      "failure" => failure,
      "by" => "grace@example.com",
      "at" => "2026-10-12T10:00:00Z"
    }

  defp listed(in_force, before \\ []),
    do: %{
      "application" => "ledger",
      "environment" => "staging",
      "in_force" => in_force,
      "addresses" => [@address],
      "before" => before
    }

  # The application's deployments in staging, one answer for each read, the last one repeated:
  # a listing, or `{status, body}`.
  defp history(provider, answers) do
    {:ok, agent} = Agent.start_link(fn -> answers end)

    FakeProvider.stub_api(provider, "GET", @deployments, fn _ ->
      agent
      |> Agent.get_and_update(fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)
      |> case do
        {status, body} -> {status, body}
        body -> {200, body}
      end
    end)
  end

  defp described(provider, routes),
    do:
      FakeProvider.stub_api(provider, "GET", "/api/v1", fn _ ->
        {200,
         %{
           "component" => "ehos",
           "version" => "0.5.0",
           "commit" => nil,
           "produces" => ["ehos.api/v1"],
           "accepts" => ["ehos.manifest/v3"],
           "requires" => %{},
           "routes" => routes
         }}
      end)

  test "--no-wait sends the manifest as it is, with the environment and the image as " <>
         "parameters, and returns once the deployment is decided",
       %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 201, deployment("activating"))

    {0, stdout, ""} = ehosctl(deploy(file, ["--no-wait"]), opts)

    assert stdout == """
           Deployed ledger to staging: deployment d-1 is activating.
             image:            #{@image}
             manifest digest:  sha256:#{String.duplicate("b2", 32)}
             authority digest: sha256:#{String.duplicate("c3", 32)}
           Whether it became active is on the application's page in the console.
           """

    assert [request] = FakeProvider.requests(provider, "POST /api/v1/deployments")
    assert request.body == @manifest
    assert request.content_type == "application/json"
    assert request.query == %{"environment" => "staging", "image" => @image}
    assert FakeProvider.requests(provider, "GET #{@deployments}") == []
  end

  describe "--graph (eh-os D-123, eh-os#785)" do
    # A domain's graph document as `mix eh_os_contract.graph --output` writes it, in the client's
    # language.
    @graph ~s({"schema": "eh_os_contract.graph.v1", "kind": "domain", "name": "ledger", "label": "Księga"}\n)

    # The parts of a multipart body, by the boundary its content type names, each a name and bytes.
    defp parts(%{content_type: "multipart/form-data; boundary=" <> boundary, body: body}) do
      [preamble | rest] = String.split(body, "--" <> boundary)
      assert preamble == ""
      {parts, ["--\r\n"]} = Enum.split(rest, -1)

      for "\r\n" <> part <- parts do
        [headers, bytes] = String.split(part, "\r\n\r\n", parts: 2)
        [_, name] = Regex.run(~r/name="([^"]+)"/, headers)
        {name, String.replace_suffix(bytes, "\r\n", "")}
      end
    end

    test "sends each document after the manifest, as their bytes are, in one multipart body",
         %{provider: provider, opts: opts, manifest: file, tmp_dir: tmp_dir} do
      answer(provider, 201, deployment("activating"))
      first = Path.join(tmp_dir, "ledger.json")
      second = Path.join(tmp_dir, "billing.json")
      File.write!(first, @graph)
      File.write!(second, String.replace(@graph, "ledger", "billing"))

      {0, _stdout, ""} =
        ehosctl(deploy(file, ["--no-wait", "--graph", first, "--graph", second]), opts)

      assert [request] = FakeProvider.requests(provider, "POST /api/v1/deployments")

      assert parts(request) == [
               {"manifest", @manifest},
               {"graph", @graph},
               {"graph", String.replace(@graph, "ledger", "billing")}
             ]

      assert request.query == %{"environment" => "staging", "image" => @image}
    end

    test "without it, sends the manifest alone, as before",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      {0, _stdout, ""} = ehosctl(deploy(file, ["--no-wait"]), opts)

      assert [%{content_type: "application/json", body: @manifest}] =
               FakeProvider.requests(provider, "POST /api/v1/deployments")
    end

    test "a document that cannot be sent is refused before anything is",
         %{provider: provider, opts: opts, manifest: file, tmp_dir: tmp_dir} do
      latin1 = Path.join(tmp_dir, "latin1.json")
      File.write!(latin1, <<0xE9>>)
      large = Path.join(tmp_dir, "large.json")
      File.write!(large, String.duplicate(" ", 1_048_577))

      {2, "", stderr} = ehosctl(deploy(file, ["--graph", latin1]), opts)
      assert stderr =~ "is not UTF-8, so it is not a graph document"

      {2, "", stderr} = ehosctl(deploy(file, ["--graph", large]), opts)
      assert stderr =~ "the most a graph document may be"

      {2, "", stderr} = ehosctl(deploy(file, ["--graph", Path.join(tmp_dir, "none.json")]), opts)
      assert stderr =~ "cannot read"

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
    end

    test "is refused from stdin, and past the 16 documents EHOS takes, before anything is sent",
         %{provider: provider, opts: opts, manifest: file, tmp_dir: tmp_dir} do
      graph = Path.join(tmp_dir, "ledger.json")
      File.write!(graph, @graph)

      {2, "", stderr} = ehosctl(deploy(file, ["--graph", "-"]), opts)
      assert stderr =~ "a graph document is not read from stdin"

      many = Enum.flat_map(1..17, fn _ -> ["--graph", graph] end)
      {2, "", stderr} = ehosctl(deploy(file, many), opts)
      assert stderr =~ "17 graph documents were given; EHOS takes at most 16"

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
    end

    test "is refused with --preview, as --image is", %{
      opts: opts,
      manifest: file,
      tmp_dir: tmp_dir
    } do
      graph = Path.join(tmp_dir, "ledger.json")
      File.write!(graph, @graph)

      {2, "", stderr} =
        ehosctl(
          ["deploy", "ledger", "--env", "staging", "--manifest", file, "--preview"] ++
            ["--graph", graph],
          opts
        )

      assert stderr =~ "--preview takes no --graph"
    end
  end

  # #364: a field a later EHOS adds to its answer is not read, so it is not printed either.
  test "--no-wait --json prints EHOS's answer, kept to the fields read",
       %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 201, Map.put(deployment("activating"), "added_later", true))

    {0, stdout, ""} = ehosctl(deploy(file, ["--no-wait", "--json"]), opts)
    assert JSON.decode!(stdout) == deployment("activating")
    assert FakeProvider.requests(provider, "GET #{@deployments}") == []
  end

  describe "waiting" do
    test "prints each state the deployment moves to, until it is active in force, and exits 0",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      before = [listing("d-0", "superseded")]

      history(provider, [
        listed(listing("d-1", "pending"), before),
        listed(listing("d-1", "activating"), before),
        listed(listing("d-1", "activating"), before),
        listed(listing("d-1", "active"), before)
      ])

      assert {0, stdout, ""} = ehosctl(deploy(file), opts)

      assert stdout == """
             Deployed ledger to staging: deployment d-1 is activating.
               image:            #{@image}
               manifest digest:  sha256:#{String.duplicate("b2", 32)}
               authority digest: sha256:#{String.duplicate("c3", 32)}
             Waiting until it is active, for at most 10 minutes:
               pending
               activating
               active
             Deployment d-1 is active in staging, at #{@address}.
             """

      assert [request | _] = FakeProvider.requests(provider, "GET #{@deployments}")
      assert length(FakeProvider.requests(provider, "GET #{@deployments}")) == 4
      assert request.query == %{"limit" => "5"}
    end

    test "--json prints one document at the end: EHOS's answer, with its last state, the " <>
           "outcome and the addresses",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, Map.put(deployment("activating"), "added_later", true))

      history(provider, [
        listed(listing("d-1", "activating")),
        listed(listing("d-1", "active"))
      ])

      assert {0, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)

      assert JSON.decode!(stdout) ==
               Map.merge(deployment("active"), %{
                 "outcome" => "active",
                 "addresses" => [@address]
               })
    end

    test "a deployment that failed prints its failure, and exits 1",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      failure = "Back-off pulling image \"#{@image}\""

      history(provider, [
        listed(listing("d-1", "activating")),
        listed(listing("d-1", "failed", failure))
      ])

      assert {1, stdout, stderr} = ehosctl(deploy(file), opts)
      assert String.ends_with?(stdout, "  activating\n  failed\n")
      assert stderr == "ehosctl: Deployment d-1 failed in staging: #{failure}.\n"

      assert {1, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)

      assert %{"outcome" => "failed", "state" => "failed", "failure" => ^failure} =
               JSON.decode!(stdout)
    end

    test "a deployment another replaced is said to be superseded, and exits 1",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      history(provider, [
        listed(listing("d-1", "activating")),
        listed(listing("d-2", "activating"), [listing("d-1", "superseded")])
      ])

      assert {1, stdout, stderr} = ehosctl(deploy(file), opts)
      assert String.ends_with?(stdout, "  activating\n  superseded\n")

      assert stderr ==
               "ehosctl: Deployment d-1 was superseded in staging: deployment d-2 took its " <>
                 "place.\n"
    end

    test "a deployment whose ephemeral environment was taken down is withdrawn, and exits 1",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      history(provider, [
        listed(listing("d-1", "activating")),
        listed(listing("d-1", "withdrawn"))
      ])

      assert {1, stdout, stderr} = ehosctl(deploy(file), opts)
      assert String.ends_with?(stdout, "  activating\n  withdrawn\n")

      assert stderr ==
               "ehosctl: Deployment d-1 was withdrawn: staging was taken down while it " <>
                 "rolled out.\n"

      assert {1, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)
      assert %{"outcome" => "withdrawn", "state" => "withdrawn"} = JSON.decode!(stdout)
    end

    test "a deployment EHOS says is active is, though one decided after it is in force",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      history(provider, [listed(listing("d-2", "activating"), [listing("d-1", "active")])])

      assert {0, stdout, ""} = ehosctl(deploy(file), opts)

      assert String.ends_with?(
               stdout,
               "  active\nDeployment d-1 is active in staging, at #{@address}. Deployment d-2, " <>
                 "decided after it, is activating there.\n"
             )
    end

    test "reads further apart as the wait goes on, up to ten seconds",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      test = self()

      history(
        provider,
        List.duplicate(listed(listing("d-1", "pending")), 6) ++ [listed(listing("d-1", "active"))]
      )

      opts =
        Keyword.merge(opts,
          deploy_poll_ms: 2_000,
          sleep: &send(test, {:slept, &1})
        )

      assert {0, _stdout, ""} = ehosctl(deploy(file), opts)

      for ms <- [2_000, 3_000, 4_500, 6_750, 10_000, 10_000],
          do: assert_received({:slept, ^ms})

      refute_received {:slept, _}
    end

    test "a read EHOS did not answer is tried again until the bound",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      history(provider, [
        {502, %{}},
        {503, %{"error" => "ehos_unavailable", "message" => "EHOS is unavailable now."}},
        listed(listing("d-1", "active"))
      ])

      assert {0, stdout, ""} = ehosctl(deploy(file), opts)
      assert stdout =~ "Deployment d-1 is active in staging"
      assert length(FakeProvider.requests(provider, "GET #{@deployments}")) == 3

      # Unanswered until the bound passes, it is the error, naming the deployment.
      history(provider, [{502, %{}}])
      opts = Keyword.put(opts, :deploy_wait_ms, 0)

      assert {5, _stdout, stderr} = ehosctl(deploy(file), opts)
      assert stderr =~ "Deployment d-1 was decided: `ehosctl apps show ledger` says its state."

      assert {5, "", stderr} = ehosctl(deploy(file, ["--json"]), opts)

      assert %{"error" => %{"kind" => "unreachable", "message" => message}} =
               JSON.decode!(stderr)

      assert message =~ "Deployment d-1 was decided"
    end

    test "when the bound passes first, says the state it is still in and how to look, and " <>
           "exits 5",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      history(provider, [listed(listing("d-1", "activating"))])

      assert {5, stdout, stderr} = ehosctl(deploy(file), Keyword.put(opts, :deploy_wait_ms, 0))
      assert stdout =~ "Waiting until it is active, for at most 0 seconds:\n  activating\n"

      assert stderr ==
               "ehosctl: Deployment d-1 is still activating in staging after 0 seconds, and " <>
                 "may yet become active or fail: `ehosctl apps show ledger` says its state " <>
                 "later.\n"

      assert {5, stdout, ""} =
               ehosctl(deploy(file, ["--json"]), Keyword.put(opts, :deploy_wait_ms, 0))

      assert %{"outcome" => "waiting", "state" => "activating"} = JSON.decode!(stdout)
    end

    test "an EHOS without the route is said not to be followed, and exits 0 as before",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      FakeProvider.stub_api(provider, "GET", @deployments, fn _ ->
        {404, %{"errors" => %{"detail" => "Not Found"}}}
      end)

      described(provider, [%{"method" => "POST", "path" => "/api/v1/deployments"}])

      assert {0, stdout, ""} = ehosctl(deploy(file), opts)

      assert stdout =~
               "ehosctl cannot follow it in staging: #{provider.issuer} runs EHOS 0.5.0, " <>
                 "which has no `GET #{@deployments}`"

      assert String.ends_with?(
               stdout,
               "Whether it became active is on ledger's page in the console.\n"
             )

      assert {0, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)
      assert JSON.decode!(stdout) == Map.put(deployment("activating"), "outcome", "not_followed")
    end

    test "a refusal while waiting is the error at once, and says the deployment was decided",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      FakeProvider.stub_api(provider, "GET", @deployments, fn _ ->
        {403, %{"error" => "forbidden", "message" => "Reading its deployments needs more."}}
      end)

      assert {3, _stdout, stderr} = ehosctl(deploy(file), opts)

      assert stderr ==
               "ehosctl: Reading its deployments needs more. Deployment d-1 was decided: " <>
                 "`ehosctl apps show ledger` says its state.\n"

      # EHOS records each read it refuses, so a refused one is not tried again.
      assert [_one] = FakeProvider.requests(provider, "GET #{@deployments}")
    end

    test "a deployment no longer among the newest is read among as many as EHOS lists, and " <>
           "when not there either, said to be displaced, exit 5",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      newer = for n <- 2..6, do: listing("d-#{n}", "superseded")

      # The five newest leave it out; the fifty newest hold it.
      FakeProvider.stub_api(provider, "GET", @deployments, fn
        %{query: %{"limit" => "5"}} ->
          {200, listed(listing("d-7", "activating"), newer)}

        %{query: %{"limit" => "50"}} ->
          {200, listed(listing("d-7", "activating"), newer ++ [listing("d-1", "active")])}
      end)

      assert {0, stdout, ""} = ehosctl(deploy(file), opts)
      assert stdout =~ "Deployment d-1 is active in staging"

      assert [%{query: %{"limit" => "5"}}, %{query: %{"limit" => "50"}}] =
               FakeProvider.requests(provider, "GET #{@deployments}")

      history(provider, [listed(listing("d-7", "activating"), newer)])

      assert {5, _stdout, stderr} = ehosctl(deploy(file), opts)

      assert stderr ==
               "ehosctl: Deployment d-1 is no longer among the newest deployments in staging: " <>
                 "others were decided after it, and one may have taken its place. " <>
                 "`ehosctl apps show ledger` says what is in force there.\n"

      assert {5, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)
      assert %{"deployment" => "d-1", "outcome" => "displaced"} = JSON.decode!(stdout)
    end

    test "no pause runs past the bound, and no read starts after it",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      history(provider, [listed(listing("d-1", "activating"))])
      test = self()

      opts =
        Keyword.merge(opts,
          deploy_wait_ms: 300,
          deploy_poll_ms: 5_000,
          sleep: fn ms ->
            send(test, {:slept, ms})
            Process.sleep(ms)
          end
        )

      assert {5, _stdout, _stderr} = ehosctl(deploy(file), opts)
      assert_received {:slept, ms}
      assert ms <= 300
      assert [_one] = FakeProvider.requests(provider, "GET #{@deployments}")
    end

    test "deployments that cannot be read are said so",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      for {body, said} <- [
            {%{listed(nil) | "environment" => "production"}, "cannot read."},
            {%{listed(nil) | "before" => [%{"kind" => "deployment", "id" => 1}]}, "cannot read."},
            {Map.delete(listed(nil), "addresses"), "cannot read."}
          ] do
        history(provider, [body])

        assert {1, _stdout, stderr} = ehosctl(deploy(file), opts)
        assert stderr =~ said
        assert stderr =~ "Deployment d-1 was decided"
      end
    end
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

  test "--env and --manifest are required", %{opts: opts} do
    assert {2, "", stderr} = ehosctl(["deploy", "ledger", "--image", @image], opts)
    assert stderr =~ "--env"
    assert stderr =~ "--manifest"
  end

  test "deploying needs --image, and a preview refuses one, before anything is sent",
       %{provider: provider, opts: opts, manifest: file} do
    answer(provider, 201, deployment("activating"))
    preview_answer(provider, 200, preview())

    assert {2, "",
            "ehosctl: Deploying needs --image, the image by digest: " <>
              "<registry>/<repository>@sha256:<digest>. --preview shows what the deployment " <>
              "would do without one.\n"} ==
             ehosctl(["deploy", "ledger", "--env", "staging", "--manifest", file], opts)

    assert {2, "",
            "ehosctl: --preview takes no --image: EHOS previews the manifest alone, and checks " <>
              "the image when it is deployed. Leave --image out of the preview, and give it to " <>
              "deploy.\n"} == ehosctl(deploy(file, ["--preview"]), opts)

    assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
    assert FakeProvider.requests(provider, "POST /api/v1/deployments/preview") == []
  end

  describe "where it came from" do
    @commit String.duplicate("0a", 20)

    test "--commit and --ref are sent only when given, and EHOS's stated source is printed " <>
           "beside the digest as theirs",
         %{provider: provider, opts: opts, manifest: file} do
      stated = %{
        "kind" => "stated",
        "commit" => @commit,
        "ref" => "refs/heads/main",
        "stated_by" => "grace@example.com"
      }

      answer(provider, 201, Map.put(deployment("activating"), "source", stated))

      {0, stdout, ""} =
        ehosctl(
          deploy(file, ["--no-wait", "--commit", @commit, "--ref", "refs/heads/main"]),
          opts
        )

      assert stdout =~
               "  image:            #{@image}\n" <>
                 "  source:           stated by grace@example.com: commit #{@commit}, " <>
                 "ref refs/heads/main\n" <>
                 "  manifest digest:  "

      assert [request] = FakeProvider.requests(provider, "POST /api/v1/deployments")

      assert request.query == %{
               "environment" => "staging",
               "image" => @image,
               "commit" => @commit,
               "ref" => "refs/heads/main"
             }

      {0, json, ""} =
        ehosctl(deploy(file, ["--no-wait", "--json", "--ref", "refs/heads/main"]), opts)

      assert JSON.decode!(json)["source"] == stated

      assert [_first, second] = FakeProvider.requests(provider, "POST /api/v1/deployments")

      assert second.query == %{
               "environment" => "staging",
               "image" => @image,
               "ref" => "refs/heads/main"
             }
    end

    test "a pipeline's source is printed as GitHub's token named it, for a pull request its " <>
           "test-merge commit",
         %{provider: provider, opts: opts, manifest: file} do
      run = %{
        "kind" => "github_run",
        "repository" => "example/ledger",
        "ref" => "refs/pull/42/merge",
        "commit" => @commit,
        "event" => "pull_request",
        "run_id" => 18_512_345_678,
        "run_attempt" => 1
      }

      answer(provider, 201, Map.put(deployment("activating"), "source", run))

      {0, stdout, ""} = ehosctl(deploy(file), opts)

      assert stdout =~
               "  source:           from GitHub's token: example/ledger, pull request #42, " <>
                 "test-merge commit #{@commit}, run 18512345678 (attempt 1)\n"
    end

    test "a deployment without a source prints no line for it",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, Map.put(deployment("activating"), "source", nil))

      {0, stdout, ""} = ehosctl(deploy(file, ["--no-wait"]), opts)
      refute stdout =~ "source:"
      assert [request] = FakeProvider.requests(provider, "POST /api/v1/deployments")
      assert request.query == %{"environment" => "staging", "image" => @image}
    end

    test "a commit or a ref EHOS would refuse is refused before anything is sent, and a " <>
           "preview takes neither",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      preview_answer(provider, 200, preview())

      for commit <- [String.upcase(@commit), "0a0a", @commit <> "0"] do
        assert {2, "", stderr} = ehosctl(deploy(file, ["--commit", commit]), opts)
        assert stderr =~ "a commit is 40 or 64 lowercase hexadecimal characters."
      end

      long = "refs/heads/" <> String.duplicate("a", 245)

      for ref <- [
            "refs/heads/a..b",
            "main branch",
            "refs/heads/maіn",
            "refs/heads/x.lock",
            long,
            ""
          ] do
        assert {2, "", stderr} = ehosctl(deploy(file, ["--ref", ref]), opts)
        assert stderr =~ "a ref follows git's rules for a ref name, in printable ASCII"
      end

      preview = ["deploy", "ledger", "--env", "staging", "--manifest", file, "--preview"]

      assert {2, "",
              "ehosctl: --preview takes no --commit or --ref: EHOS previews the manifest " <>
                "alone. Give them to deploy.\n"} ==
               ehosctl(preview ++ ["--commit", @commit], opts)

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
      assert FakeProvider.requests(provider, "POST /api/v1/deployments/preview") == []
    end

    test "a source of another shape is dropped, not the answer: the deployment is followed " <>
           "and printed without it",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, Map.put(deployment("activating"), "source", %{"kind" => 7}))

      assert {0, stdout, ""} = ehosctl(deploy(file), opts)
      refute stdout =~ "source:"
      assert stdout =~ "Deployment d-1 is active in staging"

      {0, json, ""} = ehosctl(deploy(file, ["--no-wait", "--json"]), opts)
      assert JSON.decode!(json)["source"] == nil
    end
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

  describe "--preview" do
    @in_force "sha256:" <> String.duplicate("d4", 32)

    defp preview_of(file, extra \\ []),
      do: ["deploy", "ledger", "--env", "staging", "--manifest", file, "--preview" | extra]

    defp preview_answer(provider, status, body),
      do:
        FakeProvider.stub_api(provider, "POST", "/api/v1/deployments/preview", fn _ ->
          {status, body}
        end)

    # A preview of a version that grows a role, needs register, which the caller holds, and
    # binds its database: one EHOS would take.
    defp preview(changes \\ %{}) do
      Map.merge(
        %{
          "application" => "ledger",
          "known" => true,
          "environment" => "staging",
          "digest" => "sha256:" <> String.duplicate("b2", 32),
          "authority_digest" => "sha256:" <> String.duplicate("c3", 32),
          "in_force" => @in_force,
          "authority" => "changed",
          "diff" => %{
            "capabilities_added" => ["ledger.close_month"],
            "capabilities_removed" => [],
            "roles_added" => [],
            "roles_removed" => [],
            "roles_grown" => %{"ledger.clerk" => ["ledger.close_month"]},
            "roles_shrunk" => %{},
            "grants_widened" => %{},
            "grants_narrowed" => %{}
          },
          "described" => %{
            "capabilities" => %{},
            "roles_added" => [],
            "redescribed" => [],
            "grants_changed" => []
          },
          "register" => %{"needed" => true, "held" => true},
          "needs" => [
            %{
              "need" => "database",
              "engine" => "postgresql",
              "version" => "17",
              "bound" => "shared-1, PostgreSQL 17, schema ledger"
            }
          ],
          "sign_in" => nil,
          "people" => nil,
          "refusals" => []
        },
        changes
      )
    end

    test "sends the manifest as it is, with the environment alone, and prints what the " <>
           "deployment would do in the deploy page's words",
         %{provider: provider, opts: opts, manifest: file} do
      preview_answer(provider, 200, preview())

      assert {0, stdout, ""} = ehosctl(preview_of(file), opts)

      assert stdout ==
               """
               What deploying ledger to staging would do; nothing was deployed.
                 manifest digest:  sha256:#{String.duplicate("b2", 32)}
                 authority digest: sha256:#{String.duplicate("c3", 32)}
                 in force now:     #{@in_force}

               It puts another authority in force in staging, which also needs \
               ehos.application.register there. You hold it.

               What its authority adds and takes away against the version in force:
                 capabilities added: ledger.close_month
                 roles that grow, giving everyone bound to them more: ledger.clerk (ledger.close_month)

                NEEDS     ASKS FOR       BOUND TO
                database  postgresql 17  shared-1, PostgreSQL 17, schema ledger

               To deploy it, run the command again without --preview, naming the image with --image.
               """

      assert [request] = FakeProvider.requests(provider, "POST /api/v1/deployments/preview")
      assert request.body == @manifest
      assert request.content_type == "application/json"
      assert request.query == %{"environment" => "staging"}
      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
    end

    test "with refusals, prints the preview with every reason, and exits 1",
         %{provider: provider, opts: opts, manifest: file} do
      refusals = [
        "needs.database: staging has no resource bound for a postgresql database",
        "it puts another authority in force in staging, which also needs " <>
          "ehos.application.register there"
      ]

      preview_answer(
        provider,
        200,
        preview(%{
          "register" => %{"needed" => true, "held" => false},
          "needs" => [
            %{
              "need" => "database",
              "engine" => "postgresql",
              "version" => nil,
              "refused" => "staging has no resource bound for a postgresql database"
            }
          ],
          "refusals" => refusals
        })
      )

      assert {1, stdout, ""} = ehosctl(preview_of(file), opts)

      assert stdout =~
               ~r/ database +postgresql +cannot be bound: staging has no resource bound for a postgresql database\n/

      assert String.ends_with?(
               stdout,
               "The deployment would be refused, for these reasons:\n" <>
                 Enum.map_join(refusals, "", &"  - #{&1}\n")
             )

      refute stdout =~ "You hold it."
      refute stdout =~ "To deploy it"

      preview_answer(provider, 200, preview(%{"refusals" => ["roles\e[2J: refused"]}))

      assert {1, stdout, ""} = ehosctl(preview_of(file), opts)

      assert String.ends_with?(
               stdout,
               "The deployment would be refused, for this reason:\n" <>
                 ~S(  - "roles\e[2J: refused") <> "\n"
             )
    end

    test "says an application EHOS does not know yet is registered by the deployment",
         %{provider: provider, opts: opts, manifest: file} do
      preview_answer(
        provider,
        200,
        preview(%{"known" => false, "in_force" => nil, "needs" => []})
      )

      assert {0, stdout, ""} = ehosctl(preview_of(file), opts)
      assert stdout =~ "  in force now:     none\n"

      assert stdout =~
               "EHOS does not know ledger yet: this deployment registers it, with this manifest " <>
                 "as its first version."

      assert stdout =~ "What its authority adds, with nothing in force in staging:\n"
      refute stdout =~ "NEEDS"
    end

    test "says a first manifest that names no capability or role names none, with nothing to differ from",
         %{provider: provider, opts: opts, manifest: file} do
      nothing = %{
        "capabilities_added" => [],
        "capabilities_removed" => [],
        "roles_added" => [],
        "roles_removed" => [],
        "roles_grown" => %{},
        "roles_shrunk" => %{}
      }

      preview_answer(
        provider,
        200,
        preview(%{"known" => false, "in_force" => nil, "diff" => nothing})
      )

      assert {0, stdout, ""} = ehosctl(preview_of(file), opts)

      assert stdout =~
               "With nothing in force in staging, its authority names no capability and no role.\n"

      refute stdout =~ "differs"
    end

    test "what EHOS names is printed quoted when it holds a control character",
         %{provider: provider, opts: opts, manifest: file} do
      need = %{
        "need" => "database",
        "engine" => "postgresql",
        "version" => nil,
        "refused" => "no resource\e[2J"
      }

      preview_answer(provider, 200, preview(%{"needs" => [need]}))

      assert {0, stdout, ""} = ehosctl(preview_of(file), opts)
      refute stdout =~ "\e"
      assert stdout =~ ~S("no resource\e[2J")
    end

    test "says a manifest that grants what is in force changes no one's authority",
         %{provider: provider, opts: opts, manifest: file} do
      empty =
        Map.new(preview()["diff"], fn {key, value} ->
          {key, if(is_map(value), do: %{}, else: [])}
        end)

      preview_answer(
        provider,
        200,
        preview(%{
          "authority" => "unchanged",
          "diff" => empty,
          "register" => %{"needed" => false, "held" => false}
        })
      )

      assert {0, stdout, ""} = ehosctl(preview_of(file), opts)

      assert stdout =~
               "This manifest grants what the version in force grants, so deploying it changes " <>
                 "no one's authority in staging."

      refute stdout =~ "ehos.application.register"
    end

    test "says what the deployment changes in sign-in and in reading the people",
         %{provider: provider, opts: opts, manifest: file} do
      sign_in = %{
        "adds" => true,
        "applications" => [
          %{"name" => "journal", "new" => true, "agreed" => false},
          %{"name" => "payroll", "new" => false, "agreed" => true}
        ]
      }

      preview_answer(
        provider,
        200,
        preview(%{"sign_in" => sign_in, "people" => %{"adds" => true}})
      )

      assert {0, stdout, ""} = ehosctl(preview_of(file), opts)

      assert stdout =~
               "This deployment signs people in to ledger through EHOS: its workload becomes a " <>
                 "client of sign-in in staging.\n"

      assert stdout =~
               ~r/ journal \(new\) +none until someone who may deploy journal in staging agrees\n/

      assert stdout =~ ~r/ payroll +agreed by its side\n/

      assert stdout =~
               "This deployment asks to read the company's people: ledger will be given a key to " <>
                 "identify itself to EHOS in staging, and reads the people only once someone who " <>
                 "manages people agrees there."

      preview_answer(
        provider,
        200,
        preview(%{
          "sign_in" => %{"adds" => false, "applications" => []},
          "people" => %{"removes" => true}
        })
      )

      assert {0, stdout, ""} = ehosctl(preview_of(file), opts)
      refute stdout =~ "sign-in"
      refute stdout =~ "ITS PAGES CALL"

      assert stdout =~
               "This deployment stops reading the company's people: the deployment in force in " <>
                 "staging asks to, and this one does not."

      preview_answer(provider, 200, preview(%{"people" => %{"adds" => false}}))

      assert {0, stdout, ""} = ehosctl(preview_of(file), opts)

      assert stdout =~
               "It reads the company's people, as the deployment in force there does, once " <>
                 "someone who manages people agrees."
    end

    test "--json prints the preview, kept to what is read, and exits 1 with refusals",
         %{provider: provider, opts: opts, manifest: file} do
      preview_answer(provider, 200, Map.put(preview(), "later", "unread"))

      assert {0, stdout, ""} = ehosctl(preview_of(file, ["--json"]), opts)
      json = JSON.decode!(stdout)

      assert json ==
               preview()
               |> Map.update!("described", &Map.delete(&1, "capabilities"))

      preview_answer(provider, 200, preview(%{"refusals" => ["a reason"]}))

      assert {1, stdout, ""} = ehosctl(preview_of(file, ["--json"]), opts)
      assert %{"refusals" => ["a reason"]} = JSON.decode!(stdout)
    end

    test "a manifest of another application is refused before anything is sent",
         %{provider: provider, opts: opts, manifest: file} do
      preview_answer(provider, 200, preview())
      File.write!(file, ~s({"application": "journal"}))

      assert {2, "",
              "ehosctl: #{file} is the manifest of journal, not of ledger; nothing was sent.\n"} ==
               ehosctl(preview_of(file), opts)

      assert FakeProvider.requests(provider, "POST /api/v1/deployments/preview") == []
    end

    test "each refusal is EHOS's sentence, and exits with its kind's code",
         %{provider: provider, opts: opts, manifest: file} do
      cases = [
        {403, "forbidden",
         "Deploying this application to staging needs ehos.application.deploy for it there, " <>
           "and ehos.application.register as well for a manifest that puts another authority " <>
           "in force.", 3},
        {404, "not_found", "There is no environment of that name.", 1},
        {413, "too_large", "The document is larger than 1048576 bytes.", 2}
      ]

      for {status, code, sentence, exit_code} <- cases do
        preview_answer(provider, status, %{"error" => code, "message" => sentence})

        assert {^exit_code, "", stderr} = ehosctl(preview_of(file), opts)
        assert stderr == "ehosctl: #{sentence}\n", code
      end

      preview_answer(provider, 422, %{
        "error" => "invalid",
        "message" => "The manifest is refused: capabilities: is required.",
        "reasons" => ["capabilities: is required"]
      })

      assert {2, "",
              "ehosctl: The manifest is refused: capabilities: is required.\n" <>
                "  - capabilities: is required\n"} == ehosctl(preview_of(file), opts)
    end

    test "an answer of another shape, or for another application or environment, is one " <>
           "ehosctl cannot read",
         %{provider: provider, opts: opts, manifest: file} do
      unreadable = [
        Map.delete(preview(), "refusals"),
        preview(%{"application" => "journal"}),
        preview(%{"environment" => "production"}),
        preview(%{"authority" => "different"}),
        preview(%{"diff" => %{}}),
        preview(%{"register" => %{"needed" => true}}),
        preview(%{"needs" => [%{"need" => "database", "engine" => "postgresql"}]}),
        preview(%{
          "needs" => [
            %{"need" => "database", "engine" => "postgresql", "bound" => "a", "refused" => "b"}
          ]
        }),
        preview(%{"sign_in" => %{"adds" => true, "applications" => [%{"name" => "journal"}]}}),
        preview(%{"people" => %{"removes" => false}}),
        preview(%{"people" => %{"removes" => true, "adds" => true}}),
        preview(%{"people" => %{"adds" => false, "removes" => "yes"}}),
        preview(%{"digest" => "sha256:b2"}),
        preview(%{"in_force" => "the one before"}),
        preview(%{"refusals" => [1]})
      ]

      for body <- unreadable do
        preview_answer(provider, 200, body)

        assert {1, "", stderr} = ehosctl(preview_of(file), opts)
        assert stderr =~ "answered with something ehosctl cannot read.", inspect(body)
      end
    end
  end
end
