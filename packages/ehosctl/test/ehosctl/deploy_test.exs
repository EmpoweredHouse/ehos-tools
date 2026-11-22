defmodule Ehosctl.DeployTest do
  use Ehosctl.SignInCase

  doctest Ehosctl.Review
  doctest Ehosctl.Mail, only: [relay: 2]

  @digest String.duplicate("a1", 32)
  @image "ghcr.io/example/ledger@sha256:#{@digest}"
  @manifest_digest "sha256:" <> String.duplicate("b2", 32)
  @authority_digest "sha256:" <> String.duplicate("c3", 32)
  @in_force "sha256:" <> String.duplicate("d4", 32)
  @commit String.duplicate("0a", 20)
  # As it was generated: its spacing and key order are what EHOS digests.
  @manifest ~s({"schema": "ehos.manifest/v3",\n  "application": "ledger", "capabilities": []}\n)
  # A domain's graph document as `mix eh_os_contract.graph --output` writes it, in the client's
  # language.
  @graph ~s({"schema": "eh_os_contract.graph.v1", "kind": "domain", "name": "ledger", "label": "Księga"}\n)

  @deployments "/api/v1/applications/ledger/environments/staging/deployments"
  # An environment's name with `$(…)`, a single quote and ESC: a shell would expand the first in
  # double quotes, and a terminal would act on the last, so no command offered to paste may hold it.
  @odd "x$(id)'\e"
  @odd_deployments "/api/v1/applications/ledger/environments/x%24%28id%29%27%1B/deployments"
  @address "https://ledger.staging.example.com"

  # What `deploy` prints once EHOS has decided `deployment("activating")`, and then as it waits,
  # or does not.
  @decided """
  ✓ EHOS decided a deployment of ledger to staging.
    Deployment         d-1
    State              activating
    Image              #{@image}
    Manifest digest    #{@manifest_digest}
    Authority digest   #{@authority_digest}
  """
  @active """

  ✓ Deployment d-1 is active in staging.
    Address   #{@address}
  """
  @not_waited """

  Next:
    ehosctl apps history ledger --env staging --installation local
  """

  # The parts of what `deploy --preview` prints for `preview/1`.
  @preview_head """
  · What a deployment of ledger to staging would do. ehosctl deployed nothing.
    Manifest digest    #{@manifest_digest}
    Authority digest   #{@authority_digest}
    In force now       #{@in_force}

  """
  @preview_head_unknown """
  · What a deployment of ledger to staging would do. ehosctl deployed nothing.
    Manifest digest    #{@manifest_digest}
    Authority digest   #{@authority_digest}
    In force now       <none>

  EHOS does not know ledger yet. This deployment registers it, with this application manifest as its first version.

  """
  @register_held """
  This deployment puts another authority in force in staging, so it also needs ehos.application.register there. You hold it.

  """
  @grows """
  What its authority adds and removes, compared with the version in force:
    capabilities added: ledger.close_month
    roles that grow, giving everyone bound to them more: ledger.clerk (ledger.close_month)

  """
  @needs_bound """
   NEEDS     ASKS FOR       BOUND TO
   database  postgresql 17  shared-1, PostgreSQL 17, schema ledger

  """

  setup %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
    login!(provider, opts)
    file = Path.join(tmp_dir, "manifest.json")
    File.write!(file, @manifest)

    # Unless a test says otherwise, the deployment is active at the first read, and a wait takes
    # no time.
    history(provider, [listed(listing("d-1", "active"))])
    stub_virtual_clock()
    %{manifest: file, opts: opts}
  end

  describe "deploy" do
    test "--no-wait sends the manifest as it is, with the environment and the image as " <>
           "parameters, and returns once the deployment is decided",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      assert ehosctl(deploy(file, ["--no-wait"]), opts) == {0, @decided <> @not_waited, ""}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == [
               posted(%{"environment" => "staging", "image" => @image})
             ]

      assert FakeProvider.requests(provider, "GET #{@deployments}") == []
    end

    # ehos-tools#364: a field a later EHOS adds to its answer is not read, so it is not printed
    # either.
    test "--no-wait --json prints EHOS's answer, kept to the fields read",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, Map.put(deployment("activating"), "added_later", true))

      {0, stdout, ""} = ehosctl(deploy(file, ["--no-wait", "--json"]), opts)
      assert JSON.decode!(stdout) == deployment("activating")
      assert FakeProvider.requests(provider, "GET #{@deployments}") == []
    end

    test "reads the manifest from stdin with -", %{provider: provider, opts: opts} do
      answer(provider, 201, deployment("activating"))

      mock_stdin(@manifest)

      assert ehosctl(deploy("-"), opts) ==
               {0, @decided <> @active, waited(~w(active))}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == [
               posted(%{"environment" => "staging", "image" => @image})
             ]
    end

    # Standard input is read as bytes (`Ehosctl.TerminalTest`).
    test "stdin's UTF-8 is sent as it came, and a manifest over 1 MiB is refused",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      manifest = ~s({"application": "ledger", "label": "Zatwierdź wpis, café"})

      mock_stdin(manifest)

      assert ehosctl(deploy("-"), opts) ==
               {0, @decided <> @active, waited(~w(active))}

      File.write!(file, String.duplicate(" ", 1_048_577))

      assert ehosctl(deploy(file), opts) ==
               {2, "",
                "ehosctl: #{file} is larger than 1048576 bytes. An application manifest " <>
                  "can have 1048576 bytes at most.\n"}

      mock_stdin(~s({"application": "ledger"}) <> String.duplicate(" ", 1_048_576))

      assert ehosctl(deploy("-"), opts) ==
               {2, "",
                "ehosctl: stdin is larger than 1048576 bytes. An application manifest " <>
                  "can have 1048576 bytes at most.\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == [
               posted(%{"environment" => "staging", "image" => @image}, manifest)
             ]
    end

    test "a refused manifest lists its reasons",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 422, %{
        "error" => "invalid",
        "message" => "The deployment was refused: the manifest is refused.",
        "reasons" => ["capabilities: is required", "roles\e[2J: unknown"]
      })

      assert ehosctl(deploy(file), opts) ==
               {2, "",
                "ehosctl: The deployment was refused: the manifest is refused.\n" <>
                  "  - capabilities: is required\n" <> ~S(  - "roles\e[2J: unknown") <> "\n"}
    end

    test "bytes that are not UTF-8 are refused, not changed, from stdin or a file",
         %{provider: provider, opts: opts, manifest: file} do
      manifest = ~s({"application": "ledger", "label": "\xFF"})

      mock_stdin(manifest)

      assert ehosctl(deploy("-"), opts) ==
               {2, "",
                "ehosctl: stdin is not UTF-8 text, so it is not an application manifest.\n"}

      File.write!(file, manifest)

      assert ehosctl(deploy(file), opts) ==
               {2, "",
                "ehosctl: #{file} is not UTF-8 text, so it is not an application manifest.\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
    end

    @tag :unix
    test "a device that never ends is read only past the bound", %{opts: opts} do
      assert ehosctl(deploy("/dev/zero"), opts) ==
               {2, "",
                "ehosctl: /dev/zero is larger than 1048576 bytes. An application manifest " <>
                  "can have 1048576 bytes at most.\n"}
    end

    test "a gateway's 502 in JSON of its own says the deployment may have been decided",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 502, %{"message" => "Internal server error"})

      assert ehosctl(deploy(file), opts) ==
               {5, "",
                "ehosctl: Internal server error EHOS may have deployed it. Before you deploy " <>
                  "again, open the page of ledger in the console and look at staging.\n"}
    end

    test "a gateway's 5xx says the deployment may have been decided",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 504, %{})

      assert ehosctl(deploy(file), opts) ==
               {5, "",
                "ehosctl: #{provider.issuer} is unavailable (HTTP 504). Try again later. EHOS may " <>
                  "have deployed it. Before you deploy again, open the page of ledger in the " <>
                  "console and look at staging.\n"}
    end

    test "an application that is not text is said so", %{opts: opts, manifest: file} do
      File.write!(file, ~s({"application": {"name": "ledger"}}))

      assert ehosctl(deploy(file), opts) ==
               {2, "",
                "ehosctl: #{file} is not an application manifest: its application is not text.\n"}
    end

    test "a 201 that cannot be read still says the deployment was decided",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, %{"deployment" => "d-1"})

      assert ehosctl(deploy(file), opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. EHOS " <>
                  "answered 201, so it decided the deployment. Open the page of ledger in the " <>
                  "console to see it in staging.\n"}
    end

    test "a manifest of another application, or none, is refused before anything is sent",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      File.write!(file, ~s({"application": "journal"}))

      assert ehosctl(deploy(file), opts) ==
               {2, "",
                "ehosctl: #{file} is the application manifest of journal, not of ledger. " <>
                  "ehosctl sent nothing.\n"}

      File.write!(file, ~s({"schema": "ehos.manifest/v3"}))

      assert ehosctl(deploy(file), opts) ==
               {2, "",
                "ehosctl: #{file} is not an application manifest: it does not name an " <>
                  "application.\n"}

      File.write!(file, "schema: ehos.manifest/v3")

      assert ehosctl(deploy(file), opts) ==
               {2, "",
                "ehosctl: #{file} is not an application manifest: it does not hold a JSON " <>
                  "object.\n"}

      assert ehosctl(deploy("nothing.json"), opts) ==
               {2, "",
                "ehosctl: nothing.json: ehosctl cannot read it (no such file or directory).\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
    end

    test "--env is required, and what to deploy", %{opts: opts} do
      assert ehosctl(["deploy", "ledger", "--image", @image], opts) ==
               {2, "", "ehosctl: missing required options: --env\n\nSee `ehosctl help deploy`.\n"}

      assert ehosctl(["deploy", "ledger", "--env", "staging", "--image", @image], opts) ==
               {2, "",
                "ehosctl: Nothing to deploy. Give --build with a build that the pipeline " <>
                  "registered, --bundle with the directory of a bundle, or --manifest with " <>
                  "--image.\n"}
    end

    test "deploying needs --image, and a preview refuses one, before anything is sent",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      preview_answer(provider, 200, preview())

      assert ehosctl(["deploy", "ledger", "--env", "staging", "--manifest", file], opts) ==
               {2, "",
                "ehosctl: A deployment needs --image, the image by digest: " <>
                  "<registry>/<repository>@sha256:<digest>. To see what the deployment would do " <>
                  "without an image, give --preview.\n"}

      assert ehosctl(deploy(file, ["--preview"]), opts) ==
               {2, "",
                "ehosctl: --preview does not accept --image: EHOS previews only the application " <>
                  "manifest, and checks the image when you deploy. Remove --image from the " <>
                  "preview.\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
      assert FakeProvider.requests(provider, "POST /api/v1/deployments/preview") == []
    end

    test "each refusal is the deploy page's sentence, and exits with its kind's code",
         %{provider: provider, opts: opts, manifest: file} do
      cases = [
        {403, "forbidden",
         "Deploying this application to staging needs ehos.application.deploy for it there, " <>
           "and ehos.application.register as well for a manifest that puts another authority " <>
           "in force.", 3},
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

        assert ehosctl(deploy(file), opts) == {exit_code, "", "ehosctl: #{sentence}\n"}, code
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

      assert ehosctl(deploy(file), opts) ==
               {5, "",
                "ehosctl: #{sentence} Deployment d-1. Its failure: admission webhook denied the " <>
                  "Deployment.\n"}

      superseded =
        "A later deployment of the application there was decided first, so this one was not " <>
          "written."

      answer(
        provider,
        409,
        Map.merge(deployment("superseded"), %{"error" => "superseded", "message" => superseded})
      )

      assert ehosctl(deploy(file), opts) == {1, "", "ehosctl: #{superseded} Deployment d-1.\n"}
    end
  end

  # eh-os D-123, eh-os#785.
  describe "deploy --graph" do
    test "sends each document after the manifest, as their bytes are, in one multipart body",
         %{provider: provider, opts: opts, manifest: file, tmp_dir: tmp_dir} do
      answer(provider, 201, deployment("activating"))
      first = Path.join(tmp_dir, "ledger.json")
      second = Path.join(tmp_dir, "billing.json")
      billing = String.replace(@graph, "ledger", "billing")
      File.write!(first, @graph)
      File.write!(second, billing)

      bytes = byte_size(@graph) + byte_size(billing)

      assert ehosctl(deploy(file, ["--no-wait", "--graph", first, "--graph", second]), opts) ==
               {0, @decided <> @not_waited,
                "==> Sending with the application manifest: 2 graph documents, #{bytes} bytes in all.\n"}

      # Under `--json`, stderr holds a refusal's document alone.
      {0, stdout, ""} = ehosctl(deploy(file, ["--no-wait", "--json", "--graph", first]), opts)
      assert JSON.decode!(stdout) == deployment("activating")

      answer(provider, 422, %{"error" => "invalid_manifest", "message" => "Refused."})
      {2, "", stderr} = ehosctl(deploy(file, ["--no-wait", "--json", "--graph", first]), opts)

      assert JSON.decode!(stderr) == %{
               "error" => %{
                 "kind" => "invalid",
                 "message" => "Refused.",
                 "code" => "invalid_manifest"
               }
             }

      query = %{"environment" => "staging", "image" => @image}

      assert provider
             |> FakeProvider.requests("POST /api/v1/deployments")
             |> Enum.map(&unbounded/1) == [
               posted_parts(query, [
                 {"manifest", @manifest},
                 {"graph", @graph},
                 {"graph", billing}
               ]),
               posted_parts(query, [{"manifest", @manifest}, {"graph", @graph}]),
               posted_parts(query, [{"manifest", @manifest}, {"graph", @graph}])
             ]
    end

    test "without it, sends the manifest alone, as before",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      assert ehosctl(deploy(file, ["--no-wait"]), opts) == {0, @decided <> @not_waited, ""}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == [
               posted(%{"environment" => "staging", "image" => @image})
             ]
    end

    test "sends 512 documents, and is refused past 32 MiB in all, before anything is sent",
         %{provider: provider, opts: opts, manifest: file, tmp_dir: tmp_dir} do
      answer(provider, 201, deployment("activating"))
      graph = Path.join(tmp_dir, "ledger.json")
      File.write!(graph, @graph)

      most = Enum.flat_map(1..512, fn _ -> ["--graph", graph] end)

      assert ehosctl(deploy(file, ["--no-wait" | most]), opts) ==
               {0, @decided <> @not_waited,
                "==> Sending with the application manifest: 512 graph documents, " <>
                  "#{512 * byte_size(@graph)} bytes in all.\n"}

      sent = [
        posted_parts(
          %{"environment" => "staging", "image" => @image},
          [{"manifest", @manifest} | List.duplicate({"graph", @graph}, 512)]
        )
      ]

      assert provider
             |> FakeProvider.requests("POST /api/v1/deployments")
             |> Enum.map(&unbounded/1) == sent

      # 32 documents of 1 MiB each are 32 MiB, the most in all; a 33rd passes it.
      mib = Path.join(tmp_dir, "mib.json")
      File.write!(mib, String.duplicate(" ", 1_048_576))

      assert ehosctl(deploy(file, Enum.flat_map(1..33, fn _ -> ["--graph", mib] end)), opts) ==
               {2, "",
                "ehosctl: The graph documents are larger than 33554432 bytes in all, the most " <>
                  "that a deployment takes. ehosctl sent nothing.\n"}

      assert provider
             |> FakeProvider.requests("POST /api/v1/deployments")
             |> Enum.map(&unbounded/1) == sent
    end

    test "a document that cannot be sent is refused before anything is",
         %{provider: provider, opts: opts, manifest: file, tmp_dir: tmp_dir} do
      latin1 = Path.join(tmp_dir, "latin1.json")
      File.write!(latin1, <<0xE9>>)
      large = Path.join(tmp_dir, "large.json")
      File.write!(large, String.duplicate(" ", 1_048_577))
      none = Path.join(tmp_dir, "none.json")

      assert ehosctl(deploy(file, ["--graph", latin1]), opts) ==
               {2, "", "ehosctl: #{latin1} is not UTF-8 text, so it is not a graph document.\n"}

      # In the words EHOS answers a part past its limit with (eh-os D-134).
      assert ehosctl(deploy(file, ["--graph", large]), opts) ==
               {2, "",
                "ehosctl: #{large} is larger than 1048576 bytes. A graph document can have 1048576 bytes at most.\n"}

      assert ehosctl(deploy(file, ["--graph", none]), opts) ==
               {2, "", "ehosctl: #{none}: ehosctl cannot read it (no such file or directory).\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
    end

    test "is refused from stdin, and past the 512 documents EHOS takes, before anything is sent",
         %{provider: provider, opts: opts, manifest: file, tmp_dir: tmp_dir} do
      graph = Path.join(tmp_dir, "ledger.json")
      File.write!(graph, @graph)

      assert ehosctl(deploy(file, ["--graph", "-"]), opts) ==
               {2, "",
                "ehosctl: --graph takes a file: ehosctl does not read a graph document from " <>
                  "stdin, and sent nothing.\n"}

      many = Enum.flat_map(1..513, fn _ -> ["--graph", graph] end)

      assert ehosctl(deploy(file, many), opts) ==
               {2, "",
                "ehosctl: You gave 513 graph documents, and a deployment takes at most 512. " <>
                  "ehosctl sent nothing.\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
    end

    test "is refused with --preview, as --image is", %{
      opts: opts,
      manifest: file,
      tmp_dir: tmp_dir
    } do
      graph = Path.join(tmp_dir, "ledger.json")
      File.write!(graph, @graph)

      assert ehosctl(preview_of(file, ["--graph", graph]), opts) ==
               {2, "",
                "ehosctl: --preview does not accept --graph: EHOS previews only the application " <>
                  "manifest. Give the graph documents when you deploy.\n"}
    end
  end

  describe "deploy, waiting until the deployment is decided" do
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

      assert ehosctl(deploy(file), opts) ==
               {0, @decided <> @active, waited(~w(pending activating active))}

      assert FakeProvider.requests(provider, "GET #{@deployments}") ==
               List.duplicate(read(5), 4)
    end

    test "--json prints one document at the end: EHOS's answer, with its last state, the " <>
           "outcome and the addresses",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, Map.put(deployment("activating"), "added_later", true))

      history(provider, [
        listed(listing("d-1", "activating")),
        listed(listing("d-1", "active"))
      ])

      {0, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)

      assert JSON.decode!(stdout) ==
               Map.merge(deployment("active"), %{
                 "outcome" => "active",
                 "addresses" => [@address]
               })
    end

    test "a deployment EHOS says is active is, though one decided after it is in force",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      history(provider, [listed(listing("d-2", "activating"), [listing("d-1", "active")])])

      assert ehosctl(deploy(file), opts) ==
               {0, @decided <> @active,
                waited(~w(active)) <>
                  "! EHOS decided deployment d-2 after this one.\n" <>
                  "  That deployment is activating there, and can take the place of this one.\n"}

      # Under --json, stderr holds no warning, whose words a script cannot read as JSON.
      history(provider, [listed(listing("d-2", "activating"), [listing("d-1", "active")])])
      assert {0, _json, ""} = ehosctl(deploy(file, ["--json"]), opts)
    end

    test "reads further apart as the wait goes on, up to ten seconds",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      history(
        provider,
        List.duplicate(listed(listing("d-1", "pending")), 6) ++ [listed(listing("d-1", "active"))]
      )

      mock_sleep(self())

      assert ehosctl(deploy(file), opts) ==
               {0, @decided <> @active, waited(~w(pending active))}

      assert slept() == [2_000, 3_000, 4_500, 6_750, 10_000, 10_000]
    end

    test "EHOS that stops answering once it decided the deployment is not a reason to deploy again",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      FakeProvider.stub_api(provider, "GET", @deployments, fn _ ->
        FakeProvider.down(provider)
        {502, %{}}
      end)

      assert ehosctl(deploy(file), opts) ==
               {5, @decided,
                waited([]) <>
                  "ehosctl: #{provider.issuer} did not answer. EHOS decided deployment d-1.\n" <>
                  to_see_state()}
    end

    test "a read EHOS did not answer is tried again until the bound",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      history(provider, [
        {502, %{}},
        {503, %{"error" => "ehos_unavailable", "message" => "EHOS is unavailable now."}},
        listed(listing("d-1", "active"))
      ])

      assert ehosctl(deploy(file), opts) ==
               {0, @decided <> @active, waited(~w(active))}

      assert FakeProvider.requests(provider, "GET #{@deployments}") ==
               List.duplicate(read(5), 3)

      # Unanswered until the bound passes, it is the error, naming the deployment.
      history(provider, [{502, %{}}])

      unavailable =
        "#{provider.issuer} is unavailable (HTTP 502). Try again later. EHOS decided " <>
          "deployment d-1."

      assert ehosctl(deploy(file), opts) ==
               {5, @decided, waited([]) <> "ehosctl: #{unavailable}\n" <> to_see_state()}

      {5, "", stderr} = ehosctl(deploy(file, ["--json"]), opts)

      assert JSON.decode!(stderr) == %{
               "error" => %{
                 "kind" => "unreachable",
                 "message" =>
                   unavailable <>
                     " To see its state, run: `ehosctl apps history ledger --env staging --installation local`.",
                 "what_to_do" => [
                   "ehosctl apps history ledger --env staging --installation local"
                 ]
               }
             }
    end

    test "an EHOS without the route is said not to be followed, and exits 0 as before",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      FakeProvider.stub_api(provider, "GET", @deployments, fn _ ->
        {404, %{"errors" => %{"detail" => "Not Found"}}}
      end)

      described(provider, [%{"method" => "POST", "path" => "/api/v1/deployments"}])

      assert ehosctl(deploy(file), opts) ==
               {0,
                @decided <>
                  "\n! ehosctl cannot follow the deployment in staging: #{provider.issuer} runs " <>
                  "EHOS 0.5.0, which has no `GET #{@deployments}`: this command needs a later " <>
                  "EHOS. The operator upgrades EHOS to have it.\n" <>
                  "  Open the page of ledger in the console to see if it became active.\n",
                waited([])}

      {0, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)
      assert JSON.decode!(stdout) == Map.put(deployment("activating"), "outcome", "not_followed")
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

      assert ehosctl(deploy(file), opts) ==
               {0, @decided <> @active,
                waited(~w(active)) <>
                  "! EHOS decided deployment d-7 after this one.\n" <>
                  "  That deployment is activating there, and can take the place of this one.\n"}

      assert FakeProvider.requests(provider, "GET #{@deployments}") == [read(5), read(50)]

      history(provider, [listed(listing("d-7", "activating"), newer)])

      assert ehosctl(deploy(file), opts) ==
               {5, @decided,
                waited([]) <>
                  "ehosctl: Deployment d-1 is no longer among the newest deployments in staging: " <>
                  "EHOS decided others after it, and one may have replaced it.\nWhat to do:\n" <>
                  "  To see what is in force there, run:\n" <>
                  "  ehosctl apps history ledger --env staging --installation local\n"}

      {5, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)
      assert JSON.decode!(stdout) == Map.put(deployment("activating"), "outcome", "displaced")
    end

    test "a deployment said to be displaced gives no command to look when the environment's name holds a character a terminal acts on",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      newer = for n <- 2..6, do: listing("d-#{n}", "superseded")

      FakeProvider.stub_api(provider, "GET", @odd_deployments, fn _ ->
        {200, %{listed(listing("d-7", "activating"), newer) | "environment" => @odd}}
      end)

      assert ehosctl(odd_deploy(file), opts) ==
               {5, odd_decided(),
                waited([]) <>
                  ~S[ehosctl: Deployment d-1 is no longer among the newest deployments in "x$(id)'\e": ] <>
                  "EHOS decided others after it, and one may have replaced it.\n"}
    end

    test "a deployment that failed prints its failure, and exits 1",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      failure = "Back-off pulling image \"#{@image}\""

      history(provider, [
        listed(listing("d-1", "activating")),
        listed(listing("d-1", "failed", failure))
      ])

      assert ehosctl(deploy(file), opts) ==
               {1, @decided,
                waited(~w(activating failed)) <>
                  "ehosctl: Deployment d-1 failed in staging: #{failure}.\n"}

      {1, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)

      assert JSON.decode!(stdout) ==
               Map.merge(deployment("failed", failure), %{
                 "outcome" => "failed",
                 "addresses" => [@address]
               })
    end

    test "a deployment another replaced is said to be superseded, and exits 1",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      history(provider, [
        listed(listing("d-1", "activating")),
        listed(listing("d-2", "activating"), [listing("d-1", "superseded")])
      ])

      assert ehosctl(deploy(file), opts) ==
               {1, @decided,
                waited(~w(activating superseded)) <>
                  "ehosctl: Deployment d-1 was superseded in staging: deployment d-2 replaced " <>
                  "it.\n"}
    end

    test "a deployment whose ephemeral environment was taken down is withdrawn, and exits 1",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      history(provider, [
        listed(listing("d-1", "activating")),
        listed(listing("d-1", "withdrawn"))
      ])

      assert ehosctl(deploy(file), opts) ==
               {1, @decided,
                waited(~w(activating withdrawn)) <>
                  "ehosctl: Deployment d-1 was withdrawn: EHOS removed staging while the " <>
                  "deployment rolled out.\n"}

      {1, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)

      assert JSON.decode!(stdout) ==
               Map.merge(deployment("withdrawn"), %{
                 "outcome" => "withdrawn",
                 "addresses" => [@address]
               })
    end

    test "when the bound passes first, says the state it is still in and how to look, and " <>
           "exits 5",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      history(provider, [listed(listing("d-1", "activating"))])

      assert ehosctl(deploy(file), opts) ==
               {5, @decided, waited(~w(activating)) <> "ehosctl: #{still_activating()}\n"}

      {5, stdout, ""} = ehosctl(deploy(file, ["--json"]), opts)

      assert JSON.decode!(stdout) ==
               Map.merge(deployment("activating"), %{
                 "outcome" => "waiting",
                 "addresses" => [@address]
               })
    end

    test "when the bound passes first, gives no command to look when the environment's name holds a character a terminal acts on",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      FakeProvider.stub_api(provider, "GET", @odd_deployments, fn _ ->
        {200, %{listed(listing("d-1", "activating")) | "environment" => @odd}}
      end)

      assert ehosctl(odd_deploy(file), opts) ==
               {5, odd_decided(),
                waited(~w(activating)) <>
                  ~S[ehosctl: Deployment d-1 is still activating in "x$(id)'\e" after 10 minutes. ] <>
                  "It can still become active or fail.\n"}
    end

    test "no pause runs past the bound, and no read starts after it",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      history(provider, [listed(listing("d-1", "activating"))])
      mock_clock(self())

      assert ehosctl(deploy(file), opts) ==
               {5, @decided, waited(~w(activating)) <> "ehosctl: #{still_activating()}\n"}

      # The pauses end at the ten minutes' bound exactly, and a read comes before each of them.
      pauses = [2_000, 3_000, 4_500, 6_750] ++ List.duplicate(10_000, 58) ++ [3_750]
      assert slept() == pauses

      assert FakeProvider.requests(provider, "GET #{@deployments}") ==
               List.duplicate(read(5), length(pauses))
    end

    test "a refusal while waiting is the error at once, and says the deployment was decided",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      FakeProvider.stub_api(provider, "GET", @deployments, fn _ ->
        {403, %{"error" => "forbidden", "message" => "Reading its deployments needs more."}}
      end)

      assert ehosctl(deploy(file), opts) ==
               {3, @decided,
                waited([]) <>
                  "ehosctl: Reading its deployments needs more. EHOS decided deployment d-1. " <>
                  "Open the page of ledger in the console to see its state.\n"}

      # EHOS records each read it refuses, so a refused one is not tried again.
      assert FakeProvider.requests(provider, "GET #{@deployments}") == [read(5)]
    end

    test "deployments that cannot be read are said so",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      for body <- [
            %{listed(nil) | "environment" => "production"},
            %{listed(nil) | "before" => [%{"kind" => "deployment", "id" => 1}]},
            Map.delete(listed(nil), "addresses")
          ] do
        history(provider, [body])

        assert ehosctl(deploy(file), opts) ==
                 {1, @decided,
                  waited([]) <>
                    "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. " <>
                    "EHOS decided deployment d-1. Run `ehosctl apps history ledger --env staging " <>
                    "--installation local` to see its state.\n"},
               inspect(body)
      end
    end

    test "a deployment that cannot be read gives no command to look when the environment's name holds a character a terminal acts on",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))

      FakeProvider.stub_api(provider, "GET", @odd_deployments, fn _ ->
        {200, Map.delete(%{listed(nil) | "environment" => @odd}, "addresses")}
      end)

      assert ehosctl(odd_deploy(file), opts) ==
               {1, odd_decided(),
                waited([]) <>
                  "ehosctl: #{provider.issuer} answered with something ehosctl cannot read. " <>
                  "EHOS decided deployment d-1.\n"}
    end
  end

  describe "deploy --commit and --ref" do
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

      assert ehosctl(
               deploy(file, ["--no-wait", "--commit", @commit, "--ref", "refs/heads/main"]),
               opts
             ) ==
               {0,
                """
                ✓ EHOS decided a deployment of ledger to staging.
                  Deployment         d-1
                  State              activating
                  Image              #{@image}
                  Source             stated by grace@example.com: commit #{@commit}, ref refs/heads/main
                  Manifest digest    #{@manifest_digest}
                  Authority digest   #{@authority_digest}
                """ <> @not_waited, ""}

      {0, json, ""} =
        ehosctl(deploy(file, ["--no-wait", "--json", "--ref", "refs/heads/main"]), opts)

      assert JSON.decode!(json) == Map.put(deployment("activating"), "source", stated)

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == [
               posted(%{
                 "environment" => "staging",
                 "image" => @image,
                 "commit" => @commit,
                 "ref" => "refs/heads/main"
               }),
               posted(%{
                 "environment" => "staging",
                 "image" => @image,
                 "ref" => "refs/heads/main"
               })
             ]
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

      assert ehosctl(deploy(file), opts) ==
               {0,
                """
                ✓ EHOS decided a deployment of ledger to staging.
                  Deployment         d-1
                  State              activating
                  Image              #{@image}
                  Source             from GitHub's token: example/ledger, pull request #42, test-merge commit #{@commit}, run 18512345678 (attempt 1)
                  Manifest digest    #{@manifest_digest}
                  Authority digest   #{@authority_digest}
                """ <> @active, waited(~w(active))}
    end

    test "a deployment without a source prints no line for it",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, Map.put(deployment("activating"), "source", nil))

      assert ehosctl(deploy(file, ["--no-wait"]), opts) == {0, @decided <> @not_waited, ""}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == [
               posted(%{"environment" => "staging", "image" => @image})
             ]
    end

    test "a source of another shape is dropped, not the answer: the deployment is followed " <>
           "and printed without it",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, Map.put(deployment("activating"), "source", %{"kind" => 7}))

      assert ehosctl(deploy(file), opts) ==
               {0, @decided <> @active, waited(~w(active))}

      {0, json, ""} = ehosctl(deploy(file, ["--no-wait", "--json"]), opts)
      assert JSON.decode!(json) == Map.put(deployment("activating"), "source", nil)
    end

    test "a commit or a ref EHOS would refuse is refused before anything is sent, and a " <>
           "preview takes neither",
         %{provider: provider, opts: opts, manifest: file} do
      answer(provider, 201, deployment("activating"))
      preview_answer(provider, 200, preview())

      for commit <- [String.upcase(@commit), "0a0a", @commit <> "0"] do
        assert ehosctl(deploy(file, ["--commit", commit]), opts) ==
                 {2, "",
                  "ehosctl: --commit #{commit} is refused: a commit is 40 or 64 lowercase " <>
                    "hexadecimal characters.\n"}
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
        assert ehosctl(deploy(file, ["--ref", ref]), opts) ==
                 {2, "",
                  "ehosctl: --ref #{ref} is refused: a ref follows git's rules for a ref name, " <>
                    "in printable ASCII, at most 255 bytes.\n"}
      end

      assert ehosctl(preview_of(file, ["--commit", @commit]), opts) ==
               {2, "",
                "ehosctl: --preview does not accept --commit or --ref: EHOS previews only the " <>
                  "application manifest. Give them when you deploy.\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
      assert FakeProvider.requests(provider, "POST /api/v1/deployments/preview") == []
    end
  end

  describe "deploy --preview" do
    test "sends the manifest as it is, with the environment alone, and prints what the " <>
           "deployment would do in the deploy page's words",
         %{provider: provider, opts: opts, manifest: file} do
      preview_answer(provider, 200, preview())

      assert ehosctl(preview_of(file), opts) == {0, printed_preview(file), ""}

      assert FakeProvider.requests(provider, "POST /api/v1/deployments/preview") == [
               posted(%{"environment" => "staging"}, @manifest, "/api/v1/deployments/preview")
             ]

      assert FakeProvider.requests(provider, "POST /api/v1/deployments") == []
    end

    test "says an application EHOS does not know yet is registered by the deployment",
         %{provider: provider, opts: opts, manifest: file} do
      preview_answer(
        provider,
        200,
        preview(%{"known" => false, "in_force" => nil, "needs" => []})
      )

      assert ehosctl(preview_of(file), opts) ==
               {0,
                @preview_head_unknown <>
                  @register_held <>
                  """
                  Nothing is in force in staging. What the authority of this version adds:
                    capabilities added: ledger.close_month
                    roles that grow, giving everyone bound to them more: ledger.clerk (ledger.close_month)

                  """ <> to_deploy(file), ""}
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

      assert ehosctl(preview_of(file), opts) ==
               {0,
                @preview_head_unknown <>
                  @register_held <>
                  "Nothing is in force in staging, and the authority of this application " <>
                  "manifest names no capability and no role.\n\n" <>
                  @needs_bound <> to_deploy(file), ""}
    end

    # eh-os D-135: a host outside the installation is part of the authority, as a capability is.
    test "names the hosts outside the installation the manifest adds and removes, and an " <>
           "older EHOS's preview has none",
         %{provider: provider, opts: opts, manifest: file} do
      diff =
        Map.merge(preview()["diff"], %{
          "egress_added" => ["api.example.com:443"],
          "egress_removed" => ["old.example.com:443"]
        })

      preview_answer(provider, 200, preview(%{"diff" => diff}))

      assert ehosctl(preview_of(file), opts) ==
               {0,
                @preview_head <>
                  @register_held <>
                  """
                  What its authority adds and removes, compared with the version in force:
                    capabilities added: ledger.close_month
                    roles that grow, giving everyone bound to them more: ledger.clerk (ledger.close_month)
                    hosts outside the installation added: api.example.com:443
                    hosts outside the installation removed: old.example.com:443

                  """ <> @needs_bound <> to_deploy(file), ""}

      {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
      assert JSON.decode!(json) == kept(preview(%{"diff" => diff}))

      # A first manifest that names only a host names it, with nothing in force to differ from.
      hosts_only =
        preview()["diff"]
        |> Map.new(fn {key, value} -> {key, if(is_map(value), do: %{}, else: [])} end)
        |> Map.put("egress_added", ["api.example.com:443"])

      preview_answer(
        provider,
        200,
        preview(%{"known" => false, "in_force" => nil, "diff" => hosts_only})
      )

      assert ehosctl(preview_of(file), opts) ==
               {0,
                @preview_head_unknown <>
                  @register_held <>
                  """
                  Nothing is in force in staging. What the authority of this version adds:
                    hosts outside the installation added: api.example.com:443

                  """ <> @needs_bound <> to_deploy(file), ""}

      # The preview of an EHOS that predates `needs.egress` carries neither key.
      older = Map.drop(preview()["diff"], ~w(egress_added egress_removed))
      preview_answer(provider, 200, preview(%{"diff" => older}))

      assert ehosctl(preview_of(file), opts) == {0, printed_preview(file), ""}

      {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
      assert JSON.decode!(json) == kept(preview())

      # A host that is not text is refused, as any name in a preview is.
      preview_answer(provider, 200, preview(%{"diff" => Map.put(diff, "egress_added", [443])}))

      assert ehosctl(preview_of(file), opts) == {1, "", unreadable(provider)}
    end

    # eh-os D-135: the hosts outside the installation the manifest names, beside its needs.
    test "prints the hosts outside the installation the manifest reaches after its needs, keeps " <>
           "them under --json, and an older EHOS's preview has none",
         %{provider: provider, opts: opts, manifest: file} do
      hosts = [
        %{"host" => "api.example.com", "port" => 443},
        %{"host" => "mail.example.com", "port" => 587}
      ]

      preview_answer(provider, 200, preview(%{"egress" => hosts}))

      assert ehosctl(preview_of(file), opts) ==
               {0,
                printed_preview(
                  file,
                  "Hosts outside the installation it reaches: api.example.com:443, " <>
                    "mail.example.com:587\n\n"
                ), ""}

      # An EHOS before eh-os D-141 did not check for the relay: no mark is added.
      {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
      assert JSON.decode!(json) == kept(preview(%{"egress" => hosts}))

      # None, and the preview of an EHOS that predates `needs.egress`, which carries no key.
      for answer <- [preview(), Map.delete(preview(), "egress")] do
        preview_answer(provider, 200, answer)

        assert ehosctl(preview_of(file), opts) == {0, printed_preview(file), ""}

        {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
        assert JSON.decode!(json) == kept(preview())
      end

      # A host that is not as EHOS gives it is refused, as any part of a preview is.
      for wrong <- [
            [%{"host" => 1, "port" => 443}],
            [%{"host" => "api.example.com", "port" => "443"}],
            [%{"host" => "api.example.com", "port" => 0}],
            [%{"host" => "api.example.com"}],
            ["api.example.com:443"],
            %{}
          ] do
        preview_answer(provider, 200, preview(%{"egress" => wrong}))

        assert ehosctl(preview_of(file), opts) == {1, "", unreadable(provider)}, inspect(wrong)
      end

      # A host EHOS names is printed quoted when it holds a control character.
      preview_answer(
        provider,
        200,
        preview(%{"egress" => [%{"host" => "api\e[2J.example.com", "port" => 443}]})
      )

      assert ehosctl(preview_of(file), opts) ==
               {0,
                printed_preview(
                  file,
                  ~S(Hosts outside the installation it reaches: "api\e[2J.example.com":443) <>
                    "\n\n"
                ), ""}
    end

    # eh-os D-141: a host that is the installation's mail relay is said, in the console's words,
    # and nothing is refused for it.
    test "says which hosts it reaches are the installation's mail server, and keeps the mark " <>
           "under --json",
         %{provider: provider, opts: opts, manifest: file} do
      hosts = [
        %{"host" => "api.example.com", "port" => 443, "mail_relay" => false},
        %{"host" => "smtp-relay.example.com", "port" => 465, "mail_relay" => true},
        %{"host" => "smtp-relay.example.com", "port" => 587, "mail_relay" => true}
      ]

      preview_answer(provider, 200, preview(%{"egress" => hosts}))

      assert ehosctl(preview_of(file), opts) ==
               {0,
                printed_preview(
                  file,
                  "Hosts outside the installation it reaches: api.example.com:443, " <>
                    "smtp-relay.example.com:465, smtp-relay.example.com:587\n\n"
                ), relay_warning("smtp-relay.example.com:465, smtp-relay.example.com:587 are")}

      {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
      assert JSON.decode!(json) == kept(preview(%{"egress" => hosts}))

      # No host marked, no line.
      preview_answer(provider, 200, preview(%{"egress" => [hd(hosts)]}))

      assert ehosctl(preview_of(file), opts) ==
               {0,
                printed_preview(
                  file,
                  "Hosts outside the installation it reaches: api.example.com:443\n\n"
                ), ""}

      # A mark that is not a boolean is refused, as any part of a preview is.
      for wrong <- ["true", nil, 1] do
        egress = [%{"host" => "smtp-relay.example.com", "port" => 465, "mail_relay" => wrong}]
        preview_answer(provider, 200, preview(%{"egress" => egress}))

        assert ehosctl(preview_of(file), opts) == {1, "", unreadable(provider)}, inspect(wrong)
      end

      # The relay's host is printed quoted when it holds a control character.
      egress = [%{"host" => "smtp\e[2J.example.com", "port" => 465, "mail_relay" => true}]
      preview_answer(provider, 200, preview(%{"egress" => egress}))

      assert ehosctl(preview_of(file), opts) ==
               {0,
                printed_preview(
                  file,
                  ~S(Hosts outside the installation it reaches: "smtp\e[2J.example.com":465) <>
                    "\n\n"
                ), relay_warning(~S("smtp\e[2J.example.com":465 is))}
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

      assert ehosctl(preview_of(file), opts) ==
               {0,
                @preview_head <>
                  @register_held <>
                  @grows <>
                  ~S"""
                   NEEDS     ASKS FOR    BOUND TO
                   database  postgresql  cannot be bound: "no resource\e[2J"

                  """ <> to_deploy(file), ""}
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

      assert ehosctl(preview_of(file), opts) ==
               {0,
                @preview_head <>
                  "This application manifest grants what the version in force grants. The " <>
                  "deployment changes the authority of no one in staging.\n\n" <>
                  @needs_bound <> to_deploy(file), ""}
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

      assert ehosctl(preview_of(file), opts) ==
               {0,
                printed_preview(file, """
                This deployment signs people in to ledger through EHOS. Its workload becomes a client of sign-in in staging.
                 ITS PAGES CALL  CREDENTIALS FOR IT
                 journal (new)   none until a person who can deploy journal in staging agrees
                 payroll         agreed by its side

                This deployment asks to read the people of the company. EHOS gives ledger a key to identify itself in staging. ledger reads the people only after a person who manages people agrees there.

                """), ""}

      preview_answer(
        provider,
        200,
        preview(%{
          "sign_in" => %{"adds" => false, "applications" => []},
          "people" => %{"removes" => true}
        })
      )

      assert ehosctl(preview_of(file), opts) ==
               {0,
                printed_preview(
                  file,
                  "This deployment stops reading the people of the company. The deployment in " <>
                    "force in staging asks to read them, and this one does not.\n\n"
                ), ""}

      preview_answer(provider, 200, preview(%{"people" => %{"adds" => false}}))

      assert ehosctl(preview_of(file), opts) ==
               {0,
                printed_preview(
                  file,
                  "This deployment reads the people of the company, as the deployment in force " <>
                    "there does, after a person who manages people agrees.\n\n"
                ), ""}
    end

    # eh-os D-140: the mail the deployment asks to send, against what the deployments in force ask.
    test "says the mail the deployment asks to send in the deploy page's words, and keeps it " <>
           "under --json",
         %{provider: provider, opts: opts, manifest: file} do
      external = %{
        "level" => "external",
        "reply_domains" => ["support.example.com", "example.com"]
      }

      internal = %{"level" => "internal", "reply_domains" => []}

      agree =
        "A person who holds ehos.mail.manage agrees in staging, on the Installation page or " <>
          "with `ehosctl mail agree`. The workload sends only as far as that mail agreement " <>
          "allows."

      cases = [
        {external, nil,
         "This deployment asks to send mail through EHOS to any address, with replies to " <>
           "example.com, support.example.com. " <> agree},
        {internal, nil,
         "This deployment asks to send mail through EHOS only to the people of the company. " <>
           agree},
        {nil, internal,
         "This deployment asks to send no mail. The deployment in force in staging asks to send " <>
           "mail through EHOS only to the people of the company, so the workload stops sending."},
        {external,
         %{"level" => "internal", "reply_domains" => ["example.com", "old.example.com"]},
         "This deployment asks to send mail through EHOS to any address, with replies to " <>
           "example.com, support.example.com: wider than the deployment in force, which writes " <>
           "only to the people of the company; adds replies to support.example.com; drops " <>
           "replies to old.example.com. The workload sends only as far as the mail agreement " <>
           "in staging allows."},
        {internal, %{"level" => "external", "reply_domains" => []},
         "This deployment asks to send mail through EHOS only to the people of the company: " <>
           "narrower than the deployment in force, which writes to any address. The workload " <>
           "sends only as far as the mail agreement in staging allows."},
        {internal, internal,
         "This deployment asks to send mail through EHOS only to the people of the company: as " <>
           "the deployment in force there does. The workload sends only as far as the mail " <>
           "agreement in staging allows."}
      ]

      for {mail, in_force, said} <- cases do
        answer = preview(%{"mail" => mail, "mail_in_force" => in_force})
        preview_answer(provider, 200, answer)

        assert ehosctl(preview_of(file), opts) == {0, printed_preview(file, said <> "\n\n"), ""},
               inspect({mail, in_force})

        {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
        assert JSON.decode!(json) == kept(answer)
      end

      # None asked, and the preview of an EHOS that predates mail, which carries neither key.
      for answer <- [preview(), Map.drop(preview(), ~w(mail mail_in_force))] do
        preview_answer(provider, 200, answer)

        assert ehosctl(preview_of(file), opts) == {0, printed_preview(file), ""}

        {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
        assert JSON.decode!(json) == kept(preview())
      end

      # Only the fields a request of mail holds are kept, and a domain is printed quoted when it
      # holds a control character.
      mail = %{"level" => "internal", "reply_domains" => ["ex\e[2Jample.com"]}
      preview_answer(provider, 200, preview(%{"mail" => Map.put(mail, "x", 1)}))

      assert ehosctl(preview_of(file), opts) ==
               {0,
                printed_preview(
                  file,
                  "This deployment asks to send mail through EHOS only to the people of the " <>
                    ~S(company, with replies to "ex\e[2Jample.com". ) <> agree <> "\n\n"
                ), ""}

      {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
      assert JSON.decode!(json) == kept(preview(%{"mail" => mail}))
    end

    # eh-os D-143: the CPU and memory its containers ask for, and whether the environment's quota
    # has room for it with its rollout.
    test "says what its containers ask for and whether it fits, and keeps both under --json",
         %{provider: provider, opts: opts, manifest: file} do
      own = %{"fits" => true, "whose" => "the quota of staging, its own"}
      short = %{"fits" => false, "whose" => "the installation's quota"}
      fits = "It fits the quota of staging, its own, with room for its rollout."

      cases = [
        {%{"cpu" => "250m", "memory" => "1Gi"}, own,
         "Its containers ask for 250m of CPU and 1Gi of memory, which is also the most each may " <>
           "use. " <> fits},
        {%{"cpu" => nil, "memory" => "1Gi"}, short,
         "Its containers ask for the environment's default CPU and 1Gi of memory, which is also " <>
           "the most each may use. It does not fit the installation's quota, as the refusals " <>
           "below say."},
        {%{"cpu" => "1", "memory" => nil}, own,
         "Its containers ask for 1 of CPU and the environment's default memory. " <> fits},
        {nil, own, "Its containers take the defaults of staging. " <> fits}
      ]

      for {compute, room, said} <- cases do
        answer = preview(%{"compute" => compute, "room" => room})
        preview_answer(provider, 200, answer)

        assert ehosctl(preview_of(file), opts) == {0, printed_preview(file, said <> "\n\n"), ""},
               inspect({compute, room})

        {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
        assert JSON.decode!(json) == kept(answer)
      end

      # An EHOS before D-143 says neither, and nothing is said of them.
      preview_answer(provider, 200, Map.drop(preview(), ~w(compute room)))
      assert ehosctl(preview_of(file), opts) == {0, printed_preview(file), ""}
      {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
      assert JSON.decode!(json) == kept(preview())

      # Only the fields read are kept, and a value with a control character is printed quoted.
      compute = %{"cpu" => nil, "memory" => "1G\e[2Ji"}
      room = %{"fits" => true, "whose" => "staging's"}

      preview_answer(
        provider,
        200,
        preview(%{"compute" => Map.put(compute, "x", 1), "room" => Map.put(room, "y", 2)})
      )

      assert ehosctl(preview_of(file), opts) ==
               {0,
                printed_preview(
                  file,
                  ~S(Its containers ask for the environment's default CPU and "1G\e[2Ji" of ) <>
                    "memory, which is also the most each may use. It fits staging's, with room " <>
                    "for its rollout.\n\n"
                ), ""}

      {0, json, ""} = ehosctl(preview_of(file, ["--json"]), opts)
      assert JSON.decode!(json) == kept(preview(%{"compute" => compute, "room" => room}))

      # A preview whose compute or room is not as EHOS writes them is not read.
      for wrong <- [
            %{"compute" => %{"cpu" => 250}},
            %{"room" => %{"fits" => "yes", "whose" => "x"}}
          ] do
        preview_answer(provider, 200, preview(wrong))
        assert ehosctl(preview_of(file), opts) == {1, "", unreadable(provider)}, inspect(wrong)
      end
    end

    test "--json prints the preview, kept to what is read, and exits 1 with refusals",
         %{provider: provider, opts: opts, manifest: file} do
      preview_answer(provider, 200, Map.put(preview(), "later", "unread"))

      {0, stdout, ""} = ehosctl(preview_of(file, ["--json"]), opts)

      # eh-os#722: grantable_grown is kept, none from an EHOS that does not say it.
      assert JSON.decode!(stdout) == kept(preview())

      preview_answer(provider, 200, preview(%{"refusals" => ["a reason"]}))

      {1, stdout, ""} = ehosctl(preview_of(file, ["--json"]), opts)
      assert JSON.decode!(stdout) == kept(preview(%{"refusals" => ["a reason"]}))
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

      assert ehosctl(preview_of(file), opts) ==
               {1,
                String.replace(
                  @preview_head,
                  "· What a deployment of ledger to staging would do.",
                  "✗ EHOS would refuse a deployment of ledger to staging."
                ) <>
                  @grows <>
                  """
                   NEEDS     ASKS FOR    BOUND TO
                   database  postgresql  cannot be bound: staging has no resource bound for a postgresql database

                  EHOS would refuse the deployment, for these reasons:
                    - needs.database: staging has no resource bound for a postgresql database
                    - it puts another authority in force in staging, which also needs ehos.application.register there
                  """, ""}

      preview_answer(provider, 200, preview(%{"refusals" => ["roles\e[2J: refused"]}))

      assert ehosctl(preview_of(file), opts) ==
               {1,
                String.replace(
                  printed_preview(
                    file,
                    "",
                    "EHOS would refuse the deployment, for this reason:\n" <>
                      ~S(  - "roles\e[2J: refused") <> "\n"
                  ),
                  "· What a deployment of ledger to staging would do.",
                  "✗ EHOS would refuse a deployment of ledger to staging."
                ), ""}
    end

    test "a manifest of another application is refused before anything is sent",
         %{provider: provider, opts: opts, manifest: file} do
      preview_answer(provider, 200, preview())
      File.write!(file, ~s({"application": "journal"}))

      assert ehosctl(preview_of(file), opts) ==
               {2, "",
                "ehosctl: #{file} is the application manifest of journal, not of ledger. " <>
                  "ehosctl sent nothing.\n"}

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

        assert ehosctl(preview_of(file), opts) == {exit_code, "", "ehosctl: #{sentence}\n"}, code
      end

      preview_answer(provider, 422, %{
        "error" => "invalid",
        "message" => "The manifest is refused: capabilities: is required.",
        "reasons" => ["capabilities: is required"]
      })

      assert ehosctl(preview_of(file), opts) ==
               {2, "",
                "ehosctl: The manifest is refused: capabilities: is required.\n" <>
                  "  - capabilities: is required\n"}
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
        preview(%{"mail" => %{"level" => "everyone", "reply_domains" => []}}),
        preview(%{"mail" => %{"level" => "internal"}}),
        preview(%{"mail_in_force" => %{"level" => "external", "reply_domains" => [1]}}),
        preview(%{"mail_in_force" => "internal"}),
        preview(%{"digest" => "sha256:b2"}),
        preview(%{"in_force" => "the one before"}),
        preview(%{"refusals" => [1]})
      ]

      for body <- unreadable do
        preview_answer(provider, 200, body)

        assert ehosctl(preview_of(file), opts) == {1, "", unreadable(provider)}, inspect(body)
      end
    end
  end

  defp deploy(file, extra \\ []),
    do: ["deploy", "ledger", "--env", "staging", "--image", @image, "--manifest", file | extra]

  # What `deploy` prints once EHOS has decided `deployment("activating")` in `@odd`.
  defp odd_decided,
    do: String.replace(@decided, "to staging.", ~S[to "x$(id)'\e".])

  defp odd_deploy(file),
    do: ["deploy", "ledger", "--env", @odd, "--image", @image, "--manifest", file]

  defp preview_of(file, extra \\ []),
    do: ["deploy", "ledger", "--env", "staging", "--manifest", file, "--preview" | extra]

  defp deployment(state, failure \\ nil),
    do: %{
      "deployment" => "d-1",
      "image" => @image,
      "digest" => @manifest_digest,
      "authority_digest" => @authority_digest,
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
      "manifest_digest" => @manifest_digest,
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
        "digest" => @manifest_digest,
        "authority_digest" => @authority_digest,
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
          "grants_narrowed" => %{},
          "egress_added" => [],
          "egress_removed" => []
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
        "egress" => [],
        "sign_in" => nil,
        "people" => nil,
        "mail" => nil,
        "mail_in_force" => nil,
        "compute" => nil,
        "room" => nil,
        "refusals" => []
      },
      changes
    )
  end

  # A preview as `--json` prints it: kept to what is read, so without the capabilities'
  # descriptions, and with no grantable_grown from an EHOS that does not say it.
  defp kept(preview),
    do:
      Map.update!(
        preview,
        "described",
        &(&1 |> Map.delete("capabilities") |> Map.put("grantable_grown", []))
      )

  # What `deploy --preview` prints for `preview/0`, with `after_needs`, what a test is about,
  # after its needs, and `ending` last.
  # The deployment the preview of `file` was for, under Next.
  defp to_deploy(file),
    do: """
    Next:
      ehosctl deploy ledger --env staging --manifest #{EhosPlatform.Shell.word(file)} --image IMAGE --installation local
    """

  defp printed_preview(file, after_needs \\ "", ending \\ nil),
    do:
      @preview_head <>
        @register_held <> @grows <> @needs_bound <> after_needs <> (ending || to_deploy(file))

  # The warning, on stderr, of the hosts `hosts_are` names that are the installation's mail server.
  defp relay_warning(hosts_are),
    do:
      "! #{hosts_are} the mail server of this installation.\n  If the mail server admits the " <>
        "server by its address, ledger can send through it as anyone in the domain of the " <>
        "company. That mail goes around its mail agreement and the audit record. Approve this " <>
        "only if you intend it. This path closes only when the mail server requires a user and " <>
        "no longer admits the server by its address.\n"

  # What to do when the wait cannot say the state of the deployment it decided.
  defp to_see_state,
    do:
      "What to do:\n  To see its state, run:\n  ehosctl apps history ledger --env staging --installation local\n"

  defp still_activating,
    do:
      "Deployment d-1 is still activating in staging after 10 minutes. It can still become " <>
        "active or fail.\nWhat to do:\n  To see its state later, run:\n" <>
        "  ehosctl apps history ledger --env staging --installation local"

  defp unreadable(provider),
    do: "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"

  # A request `deploy` posts to EHOS, as `FakeProvider.requests/2` keeps it.
  defp posted(query, body \\ @manifest, path \\ "/api/v1/deployments"),
    do: %{path: path, query: query, body: body, content_type: "application/json"}

  defp posted_parts(query, parts),
    do: %{
      path: "/api/v1/deployments",
      query: query,
      body: parts,
      content_type: "multipart/form-data"
    }

  # A read of the application's deployments in staging, the newest `limit` of them.
  defp read(limit),
    do: %{path: @deployments, query: %{"limit" => "#{limit}"}, body: "", content_type: nil}

  # A multipart request with its random boundary taken out, its body as its parts, each a name
  # and bytes.
  defp unbounded(%{content_type: "multipart/form-data; boundary=" <> boundary} = request) do
    [preamble | rest] = String.split(request.body, "--" <> boundary)
    assert preamble == ""
    {parts, ["--\r\n"]} = Enum.split(rest, -1)

    parts =
      for "\r\n" <> part <- parts do
        [headers, bytes] = String.split(part, "\r\n\r\n", parts: 2)
        [_, name] = Regex.run(~r/name="([^"]+)"/, headers)
        {name, String.replace_suffix(bytes, "\r\n", "")}
      end

    %{request | content_type: "multipart/form-data", body: parts}
  end

  # What a pipe gives on standard input, read as standard input is.
  defp mock_stdin(input) do
    stub(Ehosctl.TerminalMock, :read_input, fn count ->
      binary_part(input, 0, min(count, byte_size(input)))
    end)
  end

  # Each pause of the wait is sent to `test`, and takes no time.
  defp mock_sleep(test) do
    stub(Ehosctl.ClockMock, :sleep, fn ms ->
      send(test, {:slept, ms})
      :ok
    end)
  end

  # A clock that moves on only by each pause of the wait, each sent to `test`.
  defp mock_clock(test) do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    stub(Ehosctl.ClockMock, :monotonic, fn -> Agent.get(clock, & &1) end)

    stub(Ehosctl.ClockMock, :sleep, fn ms ->
      send(test, {:slept, ms})
      Agent.update(clock, &(&1 + ms))
    end)
  end

  defp slept do
    receive do
      {:slept, ms} -> [ms | slept()]
    after
      0 -> []
    end
  end

  # What `deploy` prints on stderr as it waits, and sees the deployment in each of `states`.
  defp waited(states) do
    "==> Waiting until the deployment is active, for at most 10 minutes\n" <>
      Enum.map_join(states, &"==> State of the deployment: #{&1}\n")
  end
end
