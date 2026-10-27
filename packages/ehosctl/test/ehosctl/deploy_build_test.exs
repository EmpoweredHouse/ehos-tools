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

    %{opts: Keyword.put(opts, :deploy_poll_ms, 0)}
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

  describe "--build" do
    test "names a build by its id, with no body, and prints the build it deployed",
         %{provider: provider, opts: opts} do
      answer(provider, 201, deployment(@build))

      {0, stdout, ""} = ehosctl(deploy(["--build", @build, "--no-wait"]), opts)

      assert stdout =~ "Deployed ledger to staging: deployment d-1 is activating."
      assert stdout =~ "  build:            #{@build}\n"
      assert stdout =~ "from GitHub's token: example/ledger, branch main"

      assert [request] = requests(provider)
      assert request.body == ""
      assert request.content_type == nil

      assert request.query == %{
               "environment" => "staging",
               "application" => "ledger",
               "build" => @build
             }

      # Under --json, the build is kept with the answer.
      {0, stdout, ""} = ehosctl(deploy(["--build", @build, "--no-wait", "--json"]), opts)
      assert %{"build" => @build} = JSON.decode!(stdout)
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

      assert [latest, commit] = requests(provider)

      assert latest.query == %{
               "environment" => "staging",
               "application" => "ledger",
               "build" => "latest",
               "ref" => "refs/heads/main"
             }

      assert commit.query == %{
               "environment" => "staging",
               "application" => "ledger",
               "build" => @commit,
               "repository" => "example/ledger"
             }
    end

    test "waits until the deployment is active, as one from files does",
         %{provider: provider, opts: opts} do
      answer(provider, 201, deployment(@build))

      {0, stdout, ""} = ehosctl(deploy(["--build", @build]), opts)
      assert stdout =~ "Deployment d-1 is active in staging"
    end

    test "refuses what EHOS refuses beside a build, before anything is sent",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "manifest.json")
      File.write!(file, @manifest)

      refused = [
        {["--build", @build, "--image", @image], "--build takes no --image"},
        {["--build", @build, "--manifest", file, "--commit", @commit],
         "--build takes no --manifest, --commit"},
        {["--build", @build, "--bundle", tmp_dir], "--build takes no --bundle"},
        {["--build", @build, "--graph", file], "--build takes no --graph"},
        {["--build", @build, "--preview"], "--build takes no --preview"},
        {["--build", "latest"], "--build latest needs --ref"},
        {["--build", "latest", "--ref", "main"], "--ref main is not a ref in full"},
        {["--build", "latest", "--ref", "refs/heads/a..b"], "--ref refs/heads/a..b is refused"},
        {["--build", @build, "--ref", "refs/heads/main"], "--ref is taken with --build latest"},
        {["--build", @commit, "--ref", "refs/heads/main"], "--ref is taken with --build latest"},
        {["--build", @build, "--repository", "example/ledger"],
         "--repository is taken with a commit or latest alone"},
        {["--build", "main"], "--build main names no build"},
        {["--build", String.upcase(@commit)], "names no build"}
      ]

      for {extra, said} <- refused do
        {2, "", stderr} = ehosctl(deploy(extra), opts)
        assert stderr =~ said, inspect(extra)
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
      assert stderr =~ "No build of ledger matches."
      assert stderr =~ "`ehosctl builds list ledger` lists its builds."

      answer(provider, 422, %{
        "error" => "repository_required",
        "message" => "Builds of more than one repository match."
      })

      {2, "", stderr} = ehosctl(deploy(["--build", @commit]), opts)
      assert stderr =~ "Builds of more than one repository match."
      assert stderr =~ "Name the one meant with --repository owner/name."
    end
  end

  describe "--bundle" do
    test "sends the bundle's manifest and graph documents, as their files would be",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      answer(provider, 201, Map.put(deployment(nil), "source", nil))
      dir = Path.join(tmp_dir, "bundle")
      BundleFixture.write(dir, @manifest, [{"domain.Ledger.json", @graph}])

      {0, _stdout, stderr} =
        ehosctl(deploy(["--bundle", dir, "--image", @image, "--no-wait"]), opts)

      assert stderr == "With the manifest: 1 graph document, #{byte_size(@graph)} bytes in all.\n"

      assert [request] = requests(provider)
      assert BundleFixture.parts(request) == [{"manifest", @manifest}, {"graph", @graph}]
      assert request.query == %{"environment" => "staging", "image" => @image}
    end

    test "refuses a bundle changed since it was written, or of another application",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "bundle")
      BundleFixture.write(dir, @manifest, [{"domain.json", @graph}])
      File.write!(Path.join(dir, "graph/domain.json"), String.replace(@graph, "domain", "DOMAIN"))

      {2, "", stderr} = ehosctl(deploy(["--bundle", dir, "--image", @image]), opts)
      assert stderr =~ "its SHA-256 differs"

      other = Path.join(tmp_dir, "other")
      BundleFixture.write(other, String.replace(@manifest, "ledger", "billing"), [])
      {2, "", stderr} = ehosctl(deploy(["--bundle", other, "--image", @image]), opts)
      assert stderr =~ "is the manifest of billing, not of ledger"

      assert requests(provider) == []
    end

    test "is in place of --manifest and --graph, and not taken with --preview",
         %{provider: provider, opts: opts, tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "bundle")
      BundleFixture.write(dir, @manifest, [])
      file = Path.join(dir, "ehos.manifest.json")

      {2, "", stderr} =
        ehosctl(deploy(["--bundle", dir, "--manifest", file, "--image", @image]), opts)

      assert stderr =~ "--bundle is in place of --manifest and --graph"

      {2, "", stderr} =
        ehosctl(deploy(["--bundle", dir, "--graph", file, "--image", @image]), opts)

      assert stderr =~ "--bundle is in place of --manifest and --graph"

      {2, "", stderr} = ehosctl(deploy(["--bundle", dir, "--preview"]), opts)
      assert stderr =~ "--preview takes no --bundle"
      assert stderr =~ "Give --manifest #{file} to preview it."

      {2, "", stderr} = ehosctl(deploy(["--image", @image]), opts)
      assert stderr =~ "Deploying needs what to deploy: --build"

      assert requests(provider) == []
    end
  end
end
