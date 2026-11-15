defmodule Ehosctl.BuildsTest do
  # `ehosctl builds register` and `builds list` (eh-os D-146), against EHOS's API as eh-os
  # `docs/builds-api.md` gives it, and as the console's Builds tab reads it. Not async, through
  # `Ehosctl.SignInCase`: its `ehosctl/2` captures stderr, which every process shares.
  use Ehosctl.SignInCase

  alias Ehosctl.BundleFixture

  @digest String.duplicate("a1", 32)
  @image "ghcr.io/example/ledger@sha256:#{@digest}"
  @manifest ~s({"schema": "ehos.manifest/v3",\n  "application": "ledger"}\n)
  @domain ~s({"schema": "eh_os_contract.graph.v1", "kind": "domain", "label": "Księga"}\n)
  @contract ~s({"schema": "eh_os_contract.graph.v1", "kind": "contract"}\n)
  @id "0b6f4c1e-6a8e-4f3e-9d61-2c1a7c2f9e10"
  @commit String.duplicate("c0ffee12", 5)
  @builds "/api/v1/applications/ledger/builds"
  # How a build from GitHub's token is printed.
  @source "  source: from GitHub's token: example/ledger, branch main, commit #{@commit}, " <>
            "run 51001 (attempt 1)"

  setup %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
    login!(provider, opts)
    bundle = Path.join(tmp_dir, "bundle")

    index =
      BundleFixture.write(bundle, @manifest, [
        {"domain.Ledger.json", @domain},
        {"contract.ledger.json", @contract}
      ])

    %{bundle: bundle, index: index, opts: Keyword.put(opts, :dir, tmp_dir)}
  end

  describe "register" do
    test "sends the build, the bundle's index, its manifest and each graph document in order",
         %{provider: provider, opts: opts, bundle: bundle, index: index} do
      answer(provider, "POST", 201, %{"build" => build(%{"source" => nil, "ref" => nil})})

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image], opts)

      assert stdout == """
             Registered build #{@id} of ledger.
               image:  #{@image}
               stated: nothing
             Deploy it with `ehosctl deploy ledger --env ENVIRONMENT --build #{@id}`.
             """

      assert registered(provider) == [[{"build", %{"image" => @image}} | bundle_parts(index)]]
    end

    test "sends a utility service's OpenAPI file last, as its bundle names it, as it is",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      answer(provider, "POST", 201, %{"build" => build(%{"source" => nil, "ref" => nil})})
      bundle = Path.join(tmp_dir, "service-bundle")
      openapi = %{path: "openapi.yaml", bytes: "openapi: 3.1.0\n"}
      :ok = Ehosctl.Bundle.write(bundle, @manifest, openapi)

      {0, _stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image], opts)

      assert registered(provider) == [
               [
                 {"build", %{"image" => @image}},
                 {"bundle", Ehosctl.Bundle.index(@manifest, openapi)},
                 {"manifest", @manifest},
                 {"openapi", "openapi: 3.1.0\n"}
               ]
             ]

      [request] = registrations(provider)

      assert request.body =~
               ~s(name="openapi"\r\ncontent-type: application/octet-stream\r\n\r\nopenapi: 3.1.0\n)
    end

    test "outside a GitHub Actions job states nothing, even in a checkout",
         %{provider: provider, opts: opts, bundle: bundle, index: index, tmp_dir: tmp_dir} do
      answer(provider, "POST", 201, %{"build" => build()})
      git(tmp_dir, ["init", "-q"])
      stub_env(%{"GITHUB_SHA" => @commit, "GITHUB_EVENT_NAME" => "push"})

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image], opts)

      assert stdout == """
             Registered build #{@id} of ledger.
               image:  #{@image}
             #{@source}
               stated: nothing
             Deploy it with `ehosctl deploy ledger --env ENVIRONMENT --build #{@id}`.
             """

      assert registered(provider) == [[{"build", %{"image" => @image}} | bundle_parts(index)]]
    end

    test "in a GitHub Actions job states what the checkout says, and never a commit or ref",
         %{provider: provider, opts: opts, bundle: bundle, index: index, tmp_dir: tmp_dir} do
      answer(provider, "POST", 201, %{"build" => build()})
      mock_real_runner()
      git(tmp_dir, ["init", "-q", "-b", "main"])
      git(tmp_dir, ["commit", "-q", "--allow-empty", "-m", "Start the ledger"])
      first = git(tmp_dir, ["rev-parse", "HEAD"])
      git(tmp_dir, ["commit", "-q", "--allow-empty", "-m", "Lend a book for longer"])
      sha = git(tmp_dir, ["rev-parse", "HEAD"])

      stub_env(%{
        "GITHUB_ACTIONS" => "true",
        "GITHUB_SHA" => sha,
        "GITHUB_REF" => "refs/heads/main"
      })

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image], opts)

      assert stdout == """
             Registered build #{@id} of ledger.
               image:  #{@image}
             #{@source}
               stated: the commit's title, its author, its time, 1 commit before it
             Deploy it with `ehosctl deploy ledger --env ENVIRONMENT --build #{@id}`.
             """

      stated = %{
        "title" => "Lend a book for longer",
        "author" => "Ada Lovelace",
        "committed_at" => "2026-10-27T09:30:00Z",
        "commits" => [%{"commit" => first, "title" => "Start the ledger"}]
      }

      assert registered(provider) == [
               [{"build", %{"image" => @image, "stated" => stated}} | bundle_parts(index)]
             ]
    end

    test "says a build this run registered before is the one it gets",
         %{provider: provider, opts: opts, bundle: bundle} do
      answer(provider, "POST", 200, %{"build" => build()})

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image], opts)

      assert stdout == """
             This run registered build #{@id} of ledger before, with this image and bundle.
               image:  #{@image}
             #{@source}
               stated: nothing
             Deploy it with `ehosctl deploy ledger --env ENVIRONMENT --build #{@id}`.
             """

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image, "--json"], opts)
      assert JSON.decode!(stdout) == %{"build" => build()}
    end

    test "prints no source EHOS answers of another shape, and keeps only what is stated",
         %{provider: provider, opts: opts, bundle: bundle} do
      source = %{"kind" => "github_run", "run_id" => "\e[2Jrun", "ref" => 1}

      stated = %{
        "title" => "Lend",
        "pull_request" => %{"number" => 7, "extra" => "x"},
        "commits" => [%{"commit" => @commit, "title" => "Start", "extra" => 1}]
      }

      answer(provider, "POST", 201, %{"build" => build(%{"source" => source, "stated" => stated})})

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image], opts)

      assert stdout == """
             Registered build #{@id} of ledger.
               image:  #{@image}
               stated: nothing
             Deploy it with `ehosctl deploy ledger --env ENVIRONMENT --build #{@id}`.
             """

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image, "--json"], opts)

      assert JSON.decode!(stdout) == %{
               "build" =>
                 build(%{
                   "source" => nil,
                   "stated" => %{
                     "title" => "Lend",
                     "pull_request" => %{"number" => 7},
                     "commits" => [%{"commit" => @commit, "title" => "Start"}]
                   }
                 })
             }
    end

    test "refuses an image not pinned by digest, and a bundle that is not one, before sending",
         %{provider: provider, opts: opts, bundle: bundle, tmp_dir: tmp_dir} do
      assert ehosctl(
               ["builds", "register", bundle, "--image", "ghcr.io/example/ledger:main"],
               opts
             ) ==
               {2, "",
                "ehosctl: --image ghcr.io/example/ledger:main is not pinned by digest. Give it " <>
                  "as <registry>/<repository>@sha256:<64 hexadecimal digits>. ehosctl sent " <>
                  "nothing.\n"}

      assert ehosctl(["builds", "register", tmp_dir, "--image", @image], opts) ==
               {2, "",
                "ehosctl: #{tmp_dir}/bundle.json does not exist. Give the directory of a " <>
                  "bundle. ehosctl sent nothing.\n"}

      assert registrations(provider) == []
    end

    test "prints EHOS's refusal with each reason, and when to try again",
         %{provider: provider, opts: opts, bundle: bundle} do
      answer(provider, "POST", 422, %{
        "error" => "invalid",
        "message" => "The build was refused.",
        "reasons" => ["stated.title: must be 1 to 256 characters"]
      })

      assert ehosctl(["builds", "register", bundle, "--image", @image], opts) ==
               {2, "",
                "ehosctl: The build was refused.\n  - stated.title: must be 1 to 256 characters\n"}

      FakeProvider.stub_api(provider, "POST", @builds, fn _ ->
        {429, [{"retry-after", "12"}],
         %{"error" => "too_many_calls", "message" => "Too many builds of ledger."}}
      end)

      assert ehosctl(["builds", "register", bundle, "--image", @image], opts) ==
               {5, "", "ehosctl: Too many builds of ledger. Try again in 12 seconds.\n"}

      answer(provider, "POST", 409, %{
        "error" => "already_registered",
        "message" => "This run attempt registered another bundle."
      })

      assert ehosctl(["builds", "register", bundle, "--image", @image], opts) ==
               {1, "", "ehosctl: This run attempt registered another bundle.\n"}
    end
  end

  describe "list" do
    test "lists the builds, newest first, with their ref, commit and title",
         %{provider: provider, opts: opts} do
      person =
        build(%{
          "id" => "1c7e0f2a-0000-4000-8000-000000000001",
          "ref" => nil,
          "source" => nil,
          "stated" => %{"commit" => String.duplicate("ab", 20), "ref" => "refs/heads/try"}
        })

      answer(provider, "GET", 200, %{"builds" => [build(), person]})

      {0, stdout, ""} = ehosctl(["builds", "list", "ledger"], opts)

      assert stdout == """
             Builds of ledger, newest first:
              BUILD                                 REGISTERED                   REF                      COMMIT                 TITLE
              #{@id}  2026-10-27T09:31:02.123456Z  refs/heads/main          c0ffee12c0ff           Lend a book for longer
              1c7e0f2a-0000-4000-8000-000000000001  2026-10-27T09:31:02.123456Z  refs/heads/try (stated)  abababababab (stated)  -
             Deploy one with `ehosctl deploy ledger --env ENVIRONMENT --build BUILD`.
             """

      assert FakeProvider.requests(provider, "GET #{@builds}") == [listing(%{})]
    end

    test "asks for one ref's builds, at most so many, and keeps the fields it reads under --json",
         %{provider: provider, opts: opts} do
      answer(provider, "GET", 200, %{"builds" => [build(%{"extra" => 1})]})

      {0, stdout, ""} =
        ehosctl(
          ["builds", "list", "ledger", "--ref", "refs/heads/main", "--limit", "5", "--json"],
          opts
        )

      assert JSON.decode!(stdout) == %{"application" => "ledger", "builds" => [build()]}

      assert FakeProvider.requests(provider, "GET #{@builds}") == [
               listing(%{"ref" => "refs/heads/main", "limit" => "5"})
             ]

      assert ehosctl(["builds", "list", "ledger", "--limit", "201"], opts) ==
               {2, "", "ehosctl: --limit must be a number of builds from 1 to 200.\n"}
    end

    test "says when there are none, and prints a title as text, never as a direction",
         %{provider: provider, opts: opts} do
      answer(provider, "GET", 200, %{"builds" => []})
      {0, stdout, ""} = ehosctl(["builds", "list", "ledger", "--ref", "refs/heads/main"], opts)

      assert stdout ==
               "No builds of ledger on refs/heads/main. A build shows here when the pipeline of " <>
                 "the application, or a person, runs `ehosctl builds register`.\n"

      answer(provider, "GET", 200, %{
        "builds" => [build(%{"stated" => %{"title" => "Lend \u202Ea book"}})]
      })

      {0, stdout, ""} = ehosctl(["builds", "list", "ledger"], opts)

      assert stdout == ~S"""
             Builds of ledger, newest first:
              BUILD                                 REGISTERED                   REF              COMMIT        TITLE
              0b6f4c1e-6a8e-4f3e-9d61-2c1a7c2f9e10  2026-10-27T09:31:02.123456Z  refs/heads/main  c0ffee12c0ff  "Lend \u202Ea book"
             Deploy one with `ehosctl deploy ledger --env ENVIRONMENT --build BUILD`.
             """
    end

    test "refuses an answer of another shape, and prints EHOS's refusal",
         %{provider: provider, opts: opts} do
      answer(provider, "GET", 200, %{"builds" => [%{"id" => 1}]})

      assert ehosctl(["builds", "list", "ledger"], opts) ==
               {1, "",
                "ehosctl: #{provider.issuer} answered with something ehosctl cannot read.\n"}

      answer(provider, "GET", 403, %{"error" => "forbidden", "message" => "You may not."})
      assert ehosctl(["builds", "list", "ledger"], opts) == {3, "", "ehosctl: You may not.\n"}
    end
  end

  describe "openapi" do
    test "writes a utility service's OpenAPI file as it came, named as EHOS names it",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      serve_openapi(provider, "openapi: 3.1.0\n")

      assert ehosctl(["builds", "openapi", "ledger", @id], opts) ==
               {0,
                "Wrote ledger-openapi.yaml, the OpenAPI file of build #{@id} of ledger, 15 " <>
                  "bytes, as the bundle held it.\n", ""}

      assert File.read!(Path.join(tmp_dir, "ledger-openapi.yaml")) == "openapi: 3.1.0\n"
      assert_received {:openapi_asked, "*/*", "Bearer " <> _token}
    end

    test "writes --output, and writes over no file", %{
      provider: provider,
      opts: opts,
      tmp_dir: tmp
    } do
      serve_openapi(provider, ~s({"openapi": "3.1.0"}))

      {0, _stdout, ""} =
        ehosctl(["builds", "openapi", "ledger", @id, "--output", "api.json"], opts)

      assert File.read!(Path.join(tmp, "api.json")) == ~s({"openapi": "3.1.0"})

      assert ehosctl(["builds", "openapi", "ledger", @id, "--output", "api.json"], opts) ==
               {2, "",
                "ehosctl: api.json exists. ehosctl writes over no file. Remove it, or give another " <>
                  "file with --output FILE.\n"}
    end

    test "prints EHOS's refusal, and refuses an id that is not a build's before it asks",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "#{@builds}/:id/openapi", 404, %{
        "error" => "not_found",
        "message" => "The build holds no OpenAPI file."
      })

      assert ehosctl(["builds", "openapi", "ledger", @id], opts) ==
               {1, "", "ehosctl: The build holds no OpenAPI file.\n"}

      assert ehosctl(["builds", "openapi", "ledger", "latest"], opts) ==
               {2, "",
                "ehosctl: latest is not the id of a build. `ehosctl builds list SERVICE` shows " <>
                  "the ids.\n"}
    end
  end

  # EHOS's answer to the download, the file as it came, as eh-os `docs/builds-api.md` gives it.
  defp serve_openapi(provider, bytes) do
    test = self()

    Ehosctl.FakeHTTP.stub(provider.http, "GET", "#{@builds}/:id/openapi", fn conn ->
      [accept] = Plug.Conn.get_req_header(conn, "accept")
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      send(test, {:openapi_asked, accept, authorization})

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_resp_header(
        "content-disposition",
        ~s(attachment; filename="ledger-openapi.yaml")
      )
      |> Plug.Conn.send_resp(200, bytes)
    end)
  end

  defp build(fields \\ %{}),
    do:
      Map.merge(
        %{
          "id" => @id,
          "image" => @image,
          "image_digest" => "sha256:" <> @digest,
          "manifest_digest" => "sha256:" <> String.duplicate("b2", 32),
          "bundle_digest" => String.duplicate("d4", 32),
          "ref" => "refs/heads/main",
          "source" => %{
            "kind" => "github_run",
            "repository_id" => 123_456,
            "repository" => "example/ledger",
            "ref" => "refs/heads/main",
            "commit" => @commit,
            "event" => "push",
            "workflow" => "example/ledger/.github/workflows/ci.yml@refs/heads/main",
            "run_id" => 51_001,
            "run_attempt" => 1
          },
          "stated" => %{"title" => "Lend a book for longer", "author" => "Ada Lovelace"},
          "registered_at" => "2026-10-27T09:31:02.123456Z",
          "registered_by" => "ada@example.com"
        },
        fields
      )

  defp answer(provider, method, status, body),
    do: FakeProvider.stub_api(provider, method, @builds, fn _ -> {status, body} end)

  defp listing(query), do: %{path: @builds, query: query, body: "", content_type: nil}

  defp registrations(provider), do: FakeProvider.requests(provider, "POST #{@builds}")

  # Each registration's parts, its build decoded.
  defp registered(provider),
    do:
      for(request <- registrations(provider), do: Enum.map(BundleFixture.parts(request), &part/1))

  defp part({"build", bytes}), do: {"build", JSON.decode!(bytes)}
  defp part(part), do: part

  # The parts a registration of the test's bundle sends after its build.
  defp bundle_parts(index),
    do: [
      {"bundle", index},
      {"manifest", @manifest},
      {"graph", @domain},
      {"graph", @contract}
    ]

  # The checkout is read with the real git.
  defp mock_real_runner, do: stub_with(Ehosctl.RunnerMock, Ehosctl.RunnerImpl)

  defp git(dir, args) do
    {out, 0} =
      System.cmd("git", ["-C", dir | args],
        env: [
          {"GIT_AUTHOR_NAME", "Ada Lovelace"},
          {"GIT_AUTHOR_EMAIL", "ada@example.com"},
          {"GIT_COMMITTER_NAME", "Ada Lovelace"},
          {"GIT_COMMITTER_EMAIL", "ada@example.com"},
          {"GIT_COMMITTER_DATE", "2026-10-27T09:30:00Z"}
        ]
      )

    String.trim(out)
  end
end
