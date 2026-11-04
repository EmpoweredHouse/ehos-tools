defmodule Ehosctl.DeployBuildTest do
  # `ehosctl deploy --build` and `--bundle` (eh-os D-146), against EHOS's API as eh-os
  # `docs/manifest.md`, "Deploying a build", gives it, and as the console's deploy action sends it.
  use Ehosctl.SignInCase

  alias Ehosctl.BundleFixture

  @digest String.duplicate("a1", 32)
  @image "ghcr.io/example/ledger@sha256:#{@digest}"
  @manifest ~s({"schema": "ehos.manifest/v3",\n  "application": "ledger", "capabilities": []}\n)
  @graph ~s({"schema": "eh_os_contract.graph.v1", "kind": "domain", "label": "Księga"}\n)
  @build "0b6f4c1e-6a8e-4f3e-9d61-2c1a7c2f9e10"
  @commit String.duplicate("c0ffee12", 5)

  @deployments "/api/v1/applications/ledger/environments/staging/deployments"
  @created %{
    "name" => "ledger-try",
    "type" => "ephemeral",
    "application" => "ledger",
    "template" => "small",
    "expires_at" => "2026-11-05T09:00:00Z"
  }
  @at_application "This application has the maximum number of ephemeral environments: 3. " <>
                    "Remove one, then try again."

  setup %{provider: provider, opts: opts} do
    login!(provider, opts)

    FakeProvider.stub_api(provider, "GET", @deployments, fn _ ->
      {200,
       %{
         "application" => "ledger",
         "environment" => "staging",
         "in_force" => %{
           "kind" => "deployment",
           "id" => "d-1",
           "state" => "active",
           "image" => @image,
           "manifest_digest" => "sha256:" <> String.duplicate("b2", 32),
           "failure" => nil,
           "by" => "grace@example.com",
           "at" => "2026-10-27T10:00:00Z"
         },
         "addresses" => ["https://ledger.staging.example.com"],
         "before" => []
       }}
    end)

    stub_virtual_clock()
    %{opts: opts}
  end

  describe "deploy --build" do
    test "names a build by its id, with no body, and prints the build it deployed",
         %{provider: provider, opts: opts} do
      answer(provider, 201, deployment(@build))

      {0, stdout, ""} = ehosctl(deploy(["--build", @build, "--no-wait"]), opts)

      assert stdout == """
             Deployed ledger to staging: deployment d-1 is activating.
               image:            #{@image}
               build:            #{@build}
               source:           from GitHub's token: example/ledger, branch main, commit #{@commit}, run 51001 (attempt 1)
               manifest digest:  sha256:b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
               authority digest: sha256:c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
             Open the page of the application in the console to see if it became active.
             """

      assert requests(provider) == [
               %{
                 path: "/api/v1/deployments",
                 query: %{
                   "environment" => "staging",
                   "application" => "ledger",
                   "build" => @build
                 },
                 body: "",
                 content_type: nil
               }
             ]

      # Under --json, the build is kept with the answer.
      {0, stdout, ""} = ehosctl(deploy(["--build", @build, "--no-wait", "--json"]), opts)
      assert JSON.decode!(stdout) == deployment(@build)
    end

    test "names latest of a ref in full, or a commit, each within a repository when given",
         %{provider: provider, opts: opts} do
      answer(provider, 201, deployment(@build))

      {0, _stdout, ""} =
        ehosctl(deploy(["--build", "latest", "--ref", "refs/heads/main", "--no-wait"]), opts)

      {0, _stdout, ""} =
        ehosctl(
          deploy(["--build", @commit, "--repository", "example/ledger", "--no-wait"]),
          opts
        )

      assert requests(provider) == [
               %{
                 path: "/api/v1/deployments",
                 query: %{
                   "environment" => "staging",
                   "application" => "ledger",
                   "build" => "latest",
                   "ref" => "refs/heads/main"
                 },
                 body: "",
                 content_type: nil
               },
               %{
                 path: "/api/v1/deployments",
                 query: %{
                   "environment" => "staging",
                   "application" => "ledger",
                   "build" => @commit,
                   "repository" => "example/ledger"
                 },
                 body: "",
                 content_type: nil
               }
             ]
    end

    test "waits until the deployment is active, as one from files does",
         %{provider: provider, opts: opts} do
      answer(provider, 201, deployment(@build))

      {0, stdout, ""} = ehosctl(deploy(["--build", @build]), opts)

      assert stdout == """
             Deployed ledger to staging: deployment d-1 is activating.
               image:            #{@image}
               build:            #{@build}
               source:           from GitHub's token: example/ledger, branch main, commit #{@commit}, run 51001 (attempt 1)
               manifest digest:  sha256:b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
               authority digest: sha256:c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
             ehosctl waits until the deployment is active, for at most 10 minutes:
               active
             Deployment d-1 is active in staging, at https://ledger.staging.example.com.
             """
    end

    test "refuses what EHOS refuses beside a build, before anything is sent",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "manifest.json")
      File.write!(file, @manifest)

      built =
        "a build holds its own image, application manifest and graph documents"

      names_no_build =
        "Give its id from `ehosctl builds list`, a commit of 40 or 64 lowercase hexadecimal " <>
          "characters, or latest with --ref."

      refused = [
        {["--build", @build, "--image", @image],
         "--build does not accept --image: #{built}. ehosctl sent nothing."},
        {["--build", @build, "--manifest", file, "--commit", @commit],
         "--build does not accept --manifest, --commit: #{built}. ehosctl sent nothing."},
        {["--build", @build, "--bundle", tmp_dir],
         "--build does not accept --bundle: #{built}. ehosctl sent nothing."},
        {["--build", @build, "--graph", file],
         "--build does not accept --graph: #{built}. ehosctl sent nothing."},
        {["--build", @build, "--preview"],
         "--build does not accept --preview: #{built}. ehosctl sent nothing."},
        {["--build", "latest"],
         "--build latest needs --ref, the full ref of the build, such as refs/heads/main or " <>
           "refs/pull/42/merge."},
        {["--build", "latest", "--ref", "main"],
         "--ref main is not a full ref. With --build latest, give the ref as GitHub names it, " <>
           "such as refs/heads/main."},
        {["--build", "latest", "--ref", "refs/heads/a..b"],
         "--ref refs/heads/a..b is refused: a ref follows git's rules for a ref name, in " <>
           "printable ASCII, at most 255 bytes."},
        {["--build", @build, "--ref", "refs/heads/main"],
         "--ref works only with --build latest: a commit or the id of a build names the build " <>
           "without a ref. Remove --ref."},
        {["--build", @commit, "--ref", "refs/heads/main"],
         "--ref works only with --build latest: a commit or the id of a build names the build " <>
           "without a ref. Remove --ref."},
        {["--build", @build, "--repository", "example/ledger"],
         "--repository works only with a commit or latest: the id of a build names one build. " <>
           "Remove --repository."},
        {["--build", "main"], "--build main does not name a build. #{names_no_build}"},
        {["--build", String.upcase(@commit)],
         "--build #{String.upcase(@commit)} does not name a build. #{names_no_build}"}
      ]

      for {extra, said} <- refused do
        assert {extra, ehosctl(deploy(extra), opts)} == {extra, {2, "", "ehosctl: #{said}\n"}}
      end

      assert requests(provider) == []
    end

    test "says how to find a build EHOS did not find, and how to name its repository",
         %{provider: provider, opts: opts} do
      answer(provider, 404, %{
        "error" => "build_not_found",
        "message" => "No build of ledger matches."
      })

      {1, "", stderr} = ehosctl(deploy(["--build", @commit]), opts)

      assert stderr ==
               "ehosctl: No build of ledger matches. Run `ehosctl builds list ledger` to see the " <>
                 "builds of the application.\n"

      answer(provider, 422, %{
        "error" => "repository_required",
        "message" => "Builds of more than one repository match."
      })

      {2, "", stderr} = ehosctl(deploy(["--build", @commit]), opts)

      assert stderr ==
               "ehosctl: Builds of more than one repository match. Give the repository with " <>
                 "--repository owner/name.\n"
    end
  end

  describe "deploy --build --create-env" do
    test "creates the ephemeral environment when there is none, then deploys the build to it",
         %{provider: provider, opts: opts} do
      no_environment(provider, "ledger-try")
      created(provider, 201, %{"environment" => @created})
      deploys_once_created(provider)

      {0, stdout, stderr} = ehosctl(create_env("ledger-try", ["--template", "small"]), opts)

      assert {String.split(stdout, "\n") |> hd(), stderr} ==
               {"Deployed ledger to ledger-try: deployment d-1 is activating.",
                "Created ledger-try, ephemeral, for ledger from the environment template small, " <>
                  "expires at 2026-11-05T09:00:00Z. Run `ehosctl env extend` to give it more " <>
                  "time.\n"}

      assert json_requests(provider, "POST /api/v1/environments") == [
               json_request("/api/v1/environments", %{
                 "name" => "ledger-try",
                 "type" => "ephemeral",
                 "application" => "ledger",
                 "template" => "small"
               })
             ]

      assert [%{query: %{"environment" => "ledger-try", "build" => @build}}] = requests(provider)
    end

    test "--json says the environment it created beside the deployment",
         %{provider: provider, opts: opts} do
      no_environment(provider, "ledger-try")
      created(provider, 201, %{"environment" => @created})
      deploys_once_created(provider)

      {0, stdout, ""} = ehosctl(create_env("ledger-try", ["--json"]), opts)

      assert JSON.decode!(stdout)["created_environment"] == @created

      assert json_requests(provider, "POST /api/v1/environments") == [
               json_request("/api/v1/environments", %{
                 "name" => "ledger-try",
                 "type" => "ephemeral",
                 "application" => "ledger"
               })
             ]
    end

    test "deploys to an environment that exists, and creates none",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/environments/ledger-try", 200, %{
        "environment" => Map.put(@created, "bindings", [])
      })

      answer(provider, 201, deployment(@build))

      assert {0, _stdout, ""} = ehosctl(create_env("ledger-try", []), opts)
      assert FakeProvider.requests(provider, "POST /api/v1/environments") == []
      assert length(requests(provider)) == 1
    end

    test "at the count, lists what holds it, and deploys nothing",
         %{provider: provider, opts: opts} do
      no_environment(provider, "ledger-try")

      created(provider, 409, %{
        "error" => "too_many_for_application",
        "message" => @at_application,
        "cap" => 3,
        "environments" => [
          %{
            "name" => "ledger-pr-12",
            "application" => "ledger",
            "expires_at" => "2026-11-05T09:00:00Z",
            "build" => nil
          }
        ],
        "more" => 0
      })

      assert ehosctl(create_env("ledger-try", []), opts) ==
               {1, "",
                """
                ehosctl: #{@at_application}
                These ephemeral environments count toward the maximum of 3:
                 ENVIRONMENT   APPLICATION  EXPIRES               BUILD
                 ledger-pr-12  ledger       2026-11-05T09:00:00Z  -
                Run `ehosctl env remove ENVIRONMENT` to remove one.
                """}

      {1, "", stderr} = ehosctl(create_env("ledger-try", ["--json"]), opts)
      assert JSON.decode!(stderr)["error"]["code"] == "too_many_for_application"

      assert requests(provider) == []
    end

    test "when EHOS refuses the deployment, says that the environment it created stays",
         %{provider: provider, opts: opts} do
      no_environment(provider, "ledger-try")
      created(provider, 201, %{"environment" => @created})
      answer(provider, 409, %{"error" => "no_room", "message" => "The quota has no room."})

      {1, "", stderr} = ehosctl(create_env("ledger-try", []), opts)

      assert stderr ==
               "Created ledger-try, ephemeral, for ledger from the environment template small, " <>
                 "expires at 2026-11-05T09:00:00Z. Run `ehosctl env extend` to give it more " <>
                 "time.\n" <>
                 "ehosctl: The quota has no room.\nThe ephemeral environment ledger-try, which " <>
                 "ehosctl created for the deployment, stays until it expires. Run " <>
                 "`ehosctl env remove ledger-try` to remove it.\n"

      # Under --json, as a field too, for a script to remove it.
      {1, "", stderr} = ehosctl(create_env("ledger-try", ["--json"]), opts)

      assert JSON.decode!(stderr) == %{
               "error" => %{
                 "kind" => "failed",
                 "code" => "no_room",
                 "message" =>
                   "The quota has no room.\nThe ephemeral environment ledger-try, which ehosctl " <>
                     "created for the deployment, stays until it expires. Run `ehosctl env " <>
                     "remove ledger-try` to remove it.",
                 "created_environment" => @created
               }
             }
    end

    test "when EHOS may have deployed, says so, and not that the environment stays",
         %{provider: provider, opts: opts} do
      no_environment(provider, "ledger-try")
      created(provider, 201, %{"environment" => @created})
      answer(provider, 504, "Gateway Timeout")

      {5, "", stderr} = ehosctl(create_env("ledger-try", []), opts)

      refute stderr =~ "stays until it expires"
      assert stderr =~ "EHOS may have deployed it."
    end

    test "warns before it creates or deploys to an environment a pull request may own",
         %{provider: provider, opts: opts} do
      no_environment(provider, "ledger-pr-12")
      created(provider, 201, %{"environment" => %{@created | "name" => "ledger-pr-12"}})
      answer(provider, 201, deployment(@build))

      {0, _stdout, stderr} = ehosctl(create_env("ledger-pr-12", []), opts)

      assert hd(String.split(stderr, "\n")) ==
               "If the repository previews pull requests, the pipeline of a pull request " <>
                 "deploys to ledger-pr-12. Its deployment replaces yours there and withdraws a " <>
                 "promotion that waits for a candidate there. When the pull request closes, its " <>
                 "pipeline can remove ledger-pr-12."

      # Without --create-env too, and never under --json, as the pull request's own run deploys.
      {0, _stdout, stderr} =
        ehosctl(
          ["deploy", "ledger", "--env", "ledger-pr-12", "--build", @build, "--no-wait"],
          opts
        )

      assert stderr =~ "the pipeline of a pull request deploys to ledger-pr-12."

      assert {0, _stdout, ""} =
               ehosctl(create_env("ledger-pr-12", ["--json"]), opts)
    end

    test "in a pipeline, whose credential reads no environment, says how to create one first",
         %{provider: provider, opts: opts} do
      api(provider, "GET", "/api/v1/environments/ledger-try", 403, %{
        "error" => "deployment_identity"
      })

      assert ehosctl(create_env("ledger-try", []), opts) ==
               {3, "",
                "ehosctl: A pipeline's credential may only make, deploy to and remove its " <>
                  "application's ephemeral environments. --create-env reads the environment " <>
                  "first, which a pipeline's credential cannot. In a GitHub Actions job, run " <>
                  "`ehosctl env create ledger-try --app ledger` first, then deploy without " <>
                  "--create-env.\n"}

      assert FakeProvider.requests(provider, "POST /api/v1/environments") == []
      assert requests(provider) == []
    end

    test "takes --create-env with --build alone, and --template with --create-env alone",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "manifest.json")
      File.write!(file, @manifest)

      refused = [
        {["--manifest", file, "--image", @image, "--create-env"],
         "--create-env works only with --build. Create the environment with `ehosctl env " <>
           "create --app`, or deploy a build with --build."},
        {["--manifest", file, "--image", @image, "--template", "small"],
         "--template works only with --build and --create-env. Remove --template."},
        {["--build", @build, "--template", "small"],
         "--template works only with --create-env: it names the environment template of the " <>
           "environment that ehosctl creates. Give --create-env, or remove --template."}
      ]

      for {extra, said} <- refused do
        assert {extra, ehosctl(deploy(extra), opts)} == {extra, {2, "", "ehosctl: #{said}\n"}}
      end

      assert FakeProvider.requests(provider, "GET /api/v1/environments/staging") == []
      assert requests(provider) == []
    end
  end

  describe "deploy --bundle" do
    test "sends the bundle's manifest and graph documents, as their files would be",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      answer(provider, 201, Map.put(deployment(nil), "source", nil))
      dir = Path.join(tmp_dir, "bundle")
      BundleFixture.write(dir, @manifest, [{"domain.Ledger.json", @graph}])

      {0, stdout, stderr} =
        ehosctl(deploy(["--bundle", dir, "--image", @image, "--no-wait"]), opts)

      assert stdout == """
             Deployed ledger to staging: deployment d-1 is activating.
               image:            #{@image}
               manifest digest:  sha256:b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
               authority digest: sha256:c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
             Open the page of the application in the console to see if it became active.
             """

      assert stderr ==
               "Sending with the application manifest: 1 graph document, #{byte_size(@graph)} bytes in all.\n"

      # The multipart body's boundary is a random one, so its parts are read by it.
      assert [
               %{
                 path: "/api/v1/deployments",
                 query: %{"environment" => "staging", "image" => @image},
                 content_type: "multipart/form-data; boundary=" <> _boundary
               } = request
             ] = requests(provider)

      assert BundleFixture.parts(request) == [{"manifest", @manifest}, {"graph", @graph}]
    end

    test "refuses a bundle changed since it was written, or of another application",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "bundle")
      BundleFixture.write(dir, @manifest, [{"domain.json", @graph}])
      File.write!(Path.join(dir, "graph/domain.json"), String.replace(@graph, "domain", "DOMAIN"))

      {2, "", stderr} = ehosctl(deploy(["--bundle", dir, "--image", @image]), opts)

      assert stderr ==
               "ehosctl: #{dir}/graph/domain.json is not the file that bundle.json names: its " <>
                 "SHA-256 differs. The bundle changed after `mix eh_os_contract.bundle` wrote it. " <>
                 "ehosctl sent nothing.\n"

      other = Path.join(tmp_dir, "other")
      BundleFixture.write(other, String.replace(@manifest, "ledger", "billing"), [])
      {2, "", stderr} = ehosctl(deploy(["--bundle", other, "--image", @image]), opts)

      assert stderr ==
               "ehosctl: #{other}/ehos.manifest.json is the application manifest of billing, not " <>
                 "of ledger. ehosctl sent nothing.\n"

      assert requests(provider) == []
    end

    test "is in place of --manifest and --graph, and not taken with --preview",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "bundle")
      BundleFixture.write(dir, @manifest, [])
      file = Path.join(dir, "ehos.manifest.json")

      {2, "", stderr} =
        ehosctl(deploy(["--bundle", dir, "--manifest", file, "--image", @image]), opts)

      assert stderr ==
               "ehosctl: --bundle replaces --manifest and --graph: the bundle holds the " <>
                 "application manifest and the graph documents. Give --bundle, or --manifest and " <>
                 "--graph.\n"

      {2, "", stderr} =
        ehosctl(deploy(["--bundle", dir, "--graph", file, "--image", @image]), opts)

      assert stderr ==
               "ehosctl: --bundle replaces --manifest and --graph: the bundle holds the " <>
                 "application manifest and the graph documents. Give --bundle, or --manifest and " <>
                 "--graph.\n"

      {2, "", stderr} = ehosctl(deploy(["--bundle", dir, "--preview"]), opts)

      assert stderr ==
               "ehosctl: --preview does not accept --bundle: EHOS previews only the application " <>
                 "manifest. Give --manifest #{file} to preview it.\n"

      {2, "", stderr} = ehosctl(deploy(["--image", @image]), opts)

      assert stderr ==
               "ehosctl: Nothing to deploy. Give --build with a build that the pipeline " <>
                 "registered, --bundle with the directory of a bundle, or --manifest with " <>
                 "--image.\n"

      assert requests(provider) == []
    end
  end

  defp create_env(env, extra),
    do: ["deploy", "ledger", "--env", env, "--build", @build, "--create-env", "--no-wait" | extra]

  defp no_environment(provider, name) do
    api(provider, "GET", "/api/v1/environments/#{name}", 404, %{
      "error" => "not_found",
      "message" => "No environment of that name."
    })
  end

  defp created(provider, status, body),
    do: api(provider, "POST", "/api/v1/environments", status, body)

  # The deployment is refused until the environment was created, as EHOS refuses one to an
  # environment that does not exist.
  defp deploys_once_created(provider) do
    FakeProvider.stub_api(provider, "POST", "/api/v1/deployments", fn _ ->
      if FakeProvider.requests(provider, "POST /api/v1/environments") == [],
        do: {404, %{"error" => "not_found", "message" => "No environment of that name."}},
        else: {201, deployment(@build)}
    end)
  end

  defp deploy(extra), do: ["deploy", "ledger", "--env", "staging" | extra]

  defp answer(provider, status, body),
    do: FakeProvider.stub_api(provider, "POST", "/api/v1/deployments", fn _ -> {status, body} end)

  defp deployment(build),
    do: %{
      "deployment" => "d-1",
      "image" => @image,
      "digest" => "sha256:" <> String.duplicate("b2", 32),
      "authority_digest" => "sha256:" <> String.duplicate("c3", 32),
      "state" => "activating",
      "build" => build,
      "source" => %{
        "kind" => "github_run",
        "repository" => "example/ledger",
        "ref" => "refs/heads/main",
        "commit" => @commit,
        "event" => "push",
        "run_id" => 51_001,
        "run_attempt" => 1
      }
    }

  defp requests(provider), do: FakeProvider.requests(provider, "POST /api/v1/deployments")
end
