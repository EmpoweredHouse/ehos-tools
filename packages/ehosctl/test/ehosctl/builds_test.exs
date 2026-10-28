defmodule Ehosctl.BuildsTest do
  # `ehosctl builds register` and `builds list` (eh-os D-146), against EHOS's API as eh-os
  # `docs/builds-api.md` gives it, and as the console's Builds tab reads it.
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

  defp registrations(provider), do: FakeProvider.requests(provider, "POST #{@builds}")

  describe "register" do
    test "sends the build, the bundle's index, its manifest and each graph document in order",
         %{provider: provider, opts: opts, bundle: bundle, index: index} do
      answer(provider, "POST", 201, %{"build" => build(%{"source" => nil, "ref" => nil})})

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image], opts)

      assert stdout == """
             Registered build #{@id} of ledger.
               image:  #{@image}
               stated: nothing
             Deploy it with `ehosctl deploy ledger --env <environment> --build #{@id}`.
             """

      assert [request] = registrations(provider)

      assert BundleFixture.parts(request) == [
               {"build", JSON.encode!(%{"image" => @image})},
               {"bundle", index},
               {"manifest", @manifest},
               {"graph", @domain},
               {"graph", @contract}
             ]
    end

    test "outside a GitHub Actions job states nothing, even in a checkout",
         %{provider: provider, opts: opts, bundle: bundle, tmp_dir: tmp_dir} do
      answer(provider, "POST", 201, %{"build" => build()})
      {_out, 0} = System.cmd("git", ["init", "-q", tmp_dir])

      env = %{"GITHUB_SHA" => @commit, "GITHUB_EVENT_NAME" => "push"}

      stub_env(env)

      {0, _stdout, ""} =
        ehosctl(["builds", "register", bundle, "--image", @image], opts)

      assert [request] = registrations(provider)
      assert [{"build", build} | _rest] = BundleFixture.parts(request)
      assert JSON.decode!(build) == %{"image" => @image}
    end

    test "in a GitHub Actions job states what the checkout says, and never a commit or ref",
         %{provider: provider, opts: opts, bundle: bundle, tmp_dir: tmp_dir} do
      answer(provider, "POST", 201, %{"build" => build()})
      # The checkout is read with the real git, from the repository below.
      stub_with(Ehosctl.RunnerMock, Ehosctl.RunnerImpl)

      git = fn args ->
        {out, 0} =
          System.cmd("git", ["-C", tmp_dir | args],
            env: [
              {"GIT_CONFIG_GLOBAL", "/dev/null"},
              {"GIT_AUTHOR_NAME", "Ada Lovelace"},
              {"GIT_AUTHOR_EMAIL", "ada@example.com"},
              {"GIT_COMMITTER_NAME", "Ada Lovelace"},
              {"GIT_COMMITTER_EMAIL", "ada@example.com"},
              {"GIT_COMMITTER_DATE", "2026-10-27T09:30:00Z"}
            ]
          )

        String.trim(out)
      end

      git.(["init", "-q", "-b", "main"])
      git.(["commit", "-q", "--allow-empty", "-m", "Start the ledger"])
      first = git.(["rev-parse", "HEAD"])
      git.(["commit", "-q", "--allow-empty", "-m", "Lend a book for longer"])
      sha = git.(["rev-parse", "HEAD"])

      env = %{"GITHUB_ACTIONS" => "true", "GITHUB_SHA" => sha, "GITHUB_REF" => "refs/heads/main"}

      stub_env(env)

      {0, stdout, ""} =
        ehosctl(["builds", "register", bundle, "--image", @image], opts)

      assert stdout =~ "  source: from GitHub's token: example/ledger, branch main"
      assert stdout =~ "  stated: the commit's title, its author, its time, 1 commit before it"

      assert [request] = registrations(provider)
      assert [{"build", build} | _rest] = BundleFixture.parts(request)

      assert JSON.decode!(build) == %{
               "image" => @image,
               "stated" => %{
                 "title" => "Lend a book for longer",
                 "author" => "Ada Lovelace",
                 "committed_at" => "2026-10-27T09:30:00Z",
                 "commits" => [%{"commit" => first, "title" => "Start the ledger"}]
               }
             }
    end

    test "says a build this run registered before is the one it gets",
         %{provider: provider, opts: opts, bundle: bundle} do
      answer(provider, "POST", 200, %{"build" => build()})

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image], opts)
      assert stdout =~ "Build #{@id} of ledger was registered by this run before"

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image, "--json"], opts)
      assert %{"build" => %{"id" => @id, "source" => %{"workflow" => _}}} = JSON.decode!(stdout)
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
      refute stdout =~ "\e"
      refute stdout =~ "source:"

      {0, stdout, ""} = ehosctl(["builds", "register", bundle, "--image", @image, "--json"], opts)
      %{"build" => build} = JSON.decode!(stdout)
      assert build["source"] == nil

      assert build["stated"] == %{
               "title" => "Lend",
               "pull_request" => %{"number" => 7},
               "commits" => [%{"commit" => @commit, "title" => "Start"}]
             }
    end

    test "refuses an image not pinned by digest, and a bundle that is not one, before sending",
         %{provider: provider, opts: opts, bundle: bundle, tmp_dir: tmp_dir} do
      {2, "", stderr} =
        ehosctl(["builds", "register", bundle, "--image", "ghcr.io/example/ledger:main"], opts)

      assert stderr =~ "is not pinned by digest"

      {2, "", stderr} = ehosctl(["builds", "register", tmp_dir, "--image", @image], opts)
      assert stderr =~ "bundle.json does not exist"

      assert registrations(provider) == []
    end

    test "prints EHOS's refusal with each reason, and when to try again",
         %{provider: provider, opts: opts, bundle: bundle} do
      answer(provider, "POST", 422, %{
        "error" => "invalid",
        "message" => "The build was refused.",
        "reasons" => ["stated.title: must be 1 to 256 characters"]
      })

      {2, "", stderr} = ehosctl(["builds", "register", bundle, "--image", @image], opts)
      assert stderr =~ "The build was refused.\n  - stated.title: must be 1 to 256 characters"

      FakeProvider.stub_api(provider, "POST", @builds, fn _ ->
        {429, [{"retry-after", "12"}],
         %{"error" => "too_many_calls", "message" => "Too many builds of ledger."}}
      end)

      {_code, "", stderr} = ehosctl(["builds", "register", bundle, "--image", @image], opts)
      assert stderr =~ "Too many builds of ledger. Try again in 12 seconds."

      answer(provider, "POST", 409, %{
        "error" => "already_registered",
        "message" => "This run attempt registered another bundle."
      })

      {_code, "", stderr} = ehosctl(["builds", "register", bundle, "--image", @image], opts)
      assert stderr =~ "This run attempt registered another bundle."
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

      assert stdout =~ "Builds of ledger, newest first:"

      assert stdout =~
               ~r/#{@id}\s+2026-10-27T09:31:02.123456Z\s+refs\/heads\/main\s+c0ffee12c0ff\s+Lend a book for longer/

      assert stdout =~ ~r/refs\/heads\/try \(stated\)\s+abababababab \(stated\)\s+-/

      assert stdout =~
               "Deploy one with `ehosctl deploy ledger --env <environment> --build <build>`."

      assert [request] = FakeProvider.requests(provider, "GET #{@builds}")
      assert request.query == %{}
    end

    test "asks for one ref's builds, at most so many, and keeps the fields it reads under --json",
         %{provider: provider, opts: opts} do
      answer(provider, "GET", 200, %{"builds" => [build(%{"extra" => 1})]})

      {0, stdout, ""} =
        ehosctl(
          ["builds", "list", "ledger", "--ref", "refs/heads/main", "--limit", "5", "--json"],
          opts
        )

      assert %{"application" => "ledger", "builds" => [listed]} = JSON.decode!(stdout)
      refute Map.has_key?(listed, "extra")
      assert listed["stated"]["title"] == "Lend a book for longer"

      assert [request] = FakeProvider.requests(provider, "GET #{@builds}")
      assert request.query == %{"ref" => "refs/heads/main", "limit" => "5"}

      {2, "", stderr} = ehosctl(["builds", "list", "ledger", "--limit", "201"], opts)
      assert stderr =~ "--limit is a number of builds from 1 to 200."
    end

    test "says when there are none, and prints a title as text, never as a direction",
         %{provider: provider, opts: opts} do
      answer(provider, "GET", 200, %{"builds" => []})
      {0, stdout, ""} = ehosctl(["builds", "list", "ledger", "--ref", "refs/heads/main"], opts)
      assert stdout == "No builds of ledger on refs/heads/main.\n"

      answer(provider, "GET", 200, %{
        "builds" => [build(%{"stated" => %{"title" => "Lend \u202Ea book"}})]
      })

      {0, stdout, ""} = ehosctl(["builds", "list", "ledger"], opts)
      refute stdout =~ "\u202E"
    end

    test "refuses an answer of another shape, and prints EHOS's refusal",
         %{provider: provider, opts: opts} do
      answer(provider, "GET", 200, %{"builds" => [%{"id" => 1}]})
      {_code, "", stderr} = ehosctl(["builds", "list", "ledger"], opts)
      assert stderr =~ "cannot read"

      answer(provider, "GET", 403, %{"error" => "forbidden", "message" => "You may not."})
      {_code, "", stderr} = ehosctl(["builds", "list", "ledger"], opts)
      assert stderr =~ "You may not."
    end
  end
end
