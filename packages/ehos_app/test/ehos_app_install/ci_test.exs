defmodule Mix.Tasks.EhosApp.InstallTest.CI do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  describe "CI" do
    test "gates the project with ehosctl verify, then builds the image by digest beside the bundle" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      check = workflow["jobs"]["check"]["steps"]
      runs = Enum.map(check, &(&1["run"] || &1["uses"]))

      # The gates are `ehosctl verify`'s alone, not listed again here, where they could drift
      # from what a developer runs; the `ehosctl` it pins runs the schema check too.
      assert "mise exec -- ehosctl verify" in runs

      for gate <-
            ~w(format compile test eh_os_contract.check eh_os_contract.schema eh_os_contract.manifest
               eh_os_contract.graph eh_os_contract.bundle) do
        refute Enum.any?(runs, &(&1 =~ ~r/^(mise exec -- )?mix #{Regex.escape(gate)}\b/)),
               "the check job runs mix #{gate} besides ehosctl verify"
      end

      # The dependencies are fetched first, with the token, so `verify`'s own fetch needs none.
      assert Enum.find_index(runs, &(&1 == "mix deps.get --only test --check-locked")) <
               Enum.find_index(runs, &(&1 == "mise exec -- ehosctl verify"))

      # The bundle `verify` writes, the manifest and every graph document with `bundle.json`
      # (eh-os D-146), is the artifact, and nothing beside it. With an `eh_os_contract` before
      # its bundle task, `verify` writes the manifest alone, and the job stops there, saying why,
      # rather than uploading a manifest EHOS cannot register as a build (ehos-tools#520).
      wrote = Enum.find(check, &(&1["name"] == "Check ehosctl verify wrote the bundle"))

      assert wrote["run"] =~ "if [ ! -f _build/ehos.bundle/bundle.json ]; then"
      assert wrote["run"] =~ "::error::ehosctl verify wrote no bundle into _build/ehos.bundle/"
      assert wrote["run"] =~ "exit 1"

      upload = Enum.find(check, &(&1["uses"] == "actions/upload-artifact@v7"))

      assert upload["with"] == %{
               "name" => "ehos-bundle",
               "path" => "_build/ehos.bundle",
               "if-no-files-found" => "error"
             }

      at = fn step -> Enum.find_index(check, &(&1 == step)) end
      verify = Enum.find(check, &(&1["run"] == "mise exec -- ehosctl verify"))

      assert at.(verify) + 1 == at.(wrote)
      assert at.(wrote) + 1 == at.(upload)

      image = workflow["jobs"]["image"]
      build = Enum.find(image["steps"], &(&1["id"] == "build"))

      assert image["needs"] == "check"
      assert image["permissions"]["packages"] == "write"
      assert build["with"]["secrets"] =~ "github_token="
      assert build["with"]["outputs"] =~ "push-by-digest=true"

      publish = workflow["jobs"]["publish"]

      assert publish["needs"] == "image"
      assert publish["permissions"]["packages"] == "write"
      assert Enum.any?(publish["steps"], &((&1["run"] || "") =~ "imagetools create"))
      assert Enum.any?(publish["steps"], &((&1["run"] || "") =~ "@${DIGEST}"))
    end

    test "reads EHOS's two private repositories, and nothing else, with the App's token" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      for job <- ["check", "image"] do
        token = Enum.find(workflow["jobs"][job]["steps"], &(&1["id"] == "private-deps"))
        assert token["with"]["repositories"] == "eh-os-contract,ehos-tools"
        assert token["with"]["permission-contents"] == "read"
      end

      deps_get = Enum.find(workflow["jobs"]["check"]["steps"], &(&1["name"] == "mix deps.get"))

      assert deps_get["env"]["GIT_CONFIG_COUNT"] == "2"

      assert deps_get["env"]["GIT_CONFIG_VALUE_0"] ==
               "https://github.com/EmpoweredHouse/eh-os-contract"

      assert deps_get["env"]["GIT_CONFIG_VALUE_1"] ==
               "https://github.com/EmpoweredHouse/ehos-tools"
    end

    # mise installs `ehosctl` from a private repository's releases, asking for their
    # attestations first: the token reads ehos-tools alone, with both permissions, only the step
    # that installs sees it, and that step comes before any dependency's code runs. The binary
    # runs only once it is checked against the SHA-256 its release published, since a release's
    # asset can be replaced under the same tag.
    test "installs the released ehosctl with mise, with a token that step alone sees, and checks it" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      steps = workflow["jobs"]["check"]["steps"]
      token = Enum.find(steps, &(&1["id"] == "ehosctl-release"))

      assert token["with"]["repositories"] == "ehos-tools"
      assert token["with"]["permission-contents"] == "read"
      assert token["with"]["permission-attestations"] == "read"

      install = Enum.find(steps, &(&1["name"] == "Install ehosctl"))

      assert install["run"] == "mise use -g github:EmpoweredHouse/ehos-tools@0.28.0"

      assert install["env"] == %{
               "MISE_GITHUB_TOKEN" => "${{ steps.ehosctl-release.outputs.token }}"
             }

      seen_by =
        for step <- steps, inspect(step) =~ "steps.ehosctl-release.outputs.token", do: step

      assert seen_by == [install]
      refute Enum.any?(steps -- [install], &(&1["env"] || %{})["MISE_GITHUB_TOKEN"])

      check = Enum.find(steps, &(&1["name"] == "Check ehosctl is 0.28.0's binary"))

      # ehos-tools' release v0.28.0, SHA256SUMS: `ehosctl_linux_x64`, the runner's binary.
      assert check["run"] =~
               "ba806afa5eb8112523b51e715342db11d54d3715b06e7f62911ede22cf500bab  $(mise which ehosctl)"

      assert check["run"] =~ "sha256sum --check --strict -"

      at = fn step -> Enum.find_index(steps, &(&1 == step)) end
      deps_get = Enum.find(steps, &(&1["name"] == "mix deps.get"))
      verify = Enum.find(steps, &(&1["run"] == "mise exec -- ehosctl verify"))

      assert at.(install) < at.(deps_get)
      assert at.(deps_get) < at.(check)
      assert at.(check) + 1 == at.(verify)
    end

    # `mix deps.get` prints a package's advisories and exits 0 (ehos-tools#507). The `ehosctl` the
    # job pins does not audit, so the job does, as soon as the lock's packages are known.
    test "fails on a retired or vulnerable package right after fetching the dependencies" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      runs = Enum.map(workflow["jobs"]["check"]["steps"], &(&1["run"] || &1["uses"]))

      assert Enum.find_index(runs, &(&1 == "mix deps.get --only test --check-locked")) + 1 ==
               Enum.find_index(runs, &(&1 == "mix hex.audit"))
    end

    # Each as that version wrote it, copied from its tag: `ci.yml.eex` takes no assigns.
    for version <- ~w(0.2.0 0.2.1 0.3.0 0.5.0 0.6.1 0.8.0 0.15.0 0.16.0 0.17.0 0.18.0 0.19.0) do
      test "replaces the workflow #{version} wrote, untouched since, with this version's" do
        earlier = File.read!("test/fixtures/ci_workflows/#{unquote(version)}.yml")

        upgraded =
          phx_test_project()
          |> Igniter.create_new_file(".github/workflows/ci.yml", earlier)
          |> apply_igniter!()
          |> Igniter.compose_task("ehos_app.install", [])
          |> apply_igniter!()

        assert content(upgraded, ".github/workflows/ci.yml") ==
                 installed() |> content(".github/workflows/ci.yml")

        upgraded
        |> Igniter.compose_task("ehos_app.install", [])
        |> assert_unchanged()
      end
    end

    test "leaves a workflow the developer changed, with the diff to this version's" do
      earlier = File.read!("test/fixtures/ci_workflows/0.2.0.yml")
      changed = earlier <> "      - run: mix dialyzer\n"

      igniter =
        phx_test_project()
        |> Igniter.create_new_file(".github/workflows/ci.yml", changed)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "is not what any version of ehos_app wrote" and
                   &1 =~ ~r/^ *- .*mix dialyzer/m and
                   &1 =~ ~r/^ *\+ .*repositories: eh-os-contract,ehos-tools/m)
             )

      assert igniter |> apply_igniter!() |> content(".github/workflows/ci.yml") == changed
    end

    # An image for amd64 alone does not start on Apple silicon, where Erlang/OTP fails under
    # x86-64 emulation, nor on an arm64 cluster.
    test "builds the image natively for amd64 and arm64, and deploys one index over both" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      builds =
        for %{"runner" => runner, "platform" => platform} <-
              workflow["jobs"]["image"]["strategy"]["matrix"]["include"],
            do: {platform, runner}

      assert Enum.sort(builds) == [
               {"linux/amd64", "ubuntu-24.04"},
               {"linux/arm64", "ubuntu-24.04-arm"}
             ]
    end

    # With the test environment's dependencies alone, `deps.unlock --check-unused` reports the
    # children of dev-only ones as unused, and fails every run.
    test "fetches the test environment's dependencies alone, and checks nothing that needs the rest" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      runs = Enum.map(workflow["jobs"]["check"]["steps"], &(&1["run"] || ""))

      assert "mix deps.get --only test --check-locked" in runs
      refute Enum.any?(runs, &(&1 =~ "deps.unlock"))
    end

    # A pull request of the repository gets a preview of its own on EHOS, with no stored secret
    # (eh-os D-110, ehos-tools T-18, ehos-tools#266); a fork's and a bot's get none, and the
    # environment goes when the pull request closes.
    test "deploys a pull request of the repository to an ephemeral environment of its own, links it, and removes it when it closes" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      jobs = workflow["jobs"]
      same_repository = "github.event.pull_request.head.repo.full_name == github.repository"

      assert "closed" in workflow["on"]["pull_request"]["types"]

      # One group per pull request, whose closing waits for its run rather than cancelling it: a
      # merged pull request's closing runs on the base branch's ref, which every one shares.
      assert workflow["concurrency"]["group"] ==
               "ci-${{ github.event.pull_request.number || github.ref }}"

      assert workflow["concurrency"]["cancel-in-progress"] ==
               "${{ github.event_name == 'pull_request' && github.event.action != 'closed' }}"

      assert jobs["check"]["if"] == "github.event.action != 'closed'"

      # A pull request of the repository pushes its image and publishes it, as `main` does.
      build = Enum.find(jobs["image"]["steps"], &(&1["id"] == "build"))
      assert build["with"]["outputs"] =~ same_repository
      assert jobs["publish"]["if"] =~ same_repository

      preview = jobs["preview"]

      assert preview["needs"] == "publish"
      assert preview["if"] =~ same_repository
      assert preview["if"] =~ "!endsWith(github.actor, '[bot]')"
      assert preview["if"] =~ "github.event.action != 'closed'"
      # Without an installation `publish` is skipped, and `preview` still runs to say so.
      assert preview["if"] =~ "needs.publish.result == 'success' || vars.EHOSCTL_URL == ''"
      assert jobs["publish"]["if"] =~ "vars.EHOSCTL_URL != ''"

      # The actions a job that may ask for a token EHOS accepts runs are pinned by commit.
      for job <- ["publish", "preview", "preview-remove"],
          step <- jobs[job]["steps"],
          step["uses"] do
        assert step["uses"] =~ ~r/@[0-9a-f]{40}$/, "#{job} runs #{step["uses"]} by a tag"
      end

      assert preview["permissions"] == %{
               "contents" => "read",
               "id-token" => "write",
               "pull-requests" => "write"
             }

      # The installation is two repository variables, not secrets.
      assert preview["env"]["EHOSCTL_URL"] == "${{ vars.EHOSCTL_URL }}"
      assert preview["env"]["EHOSCTL_CA_PEM"] == "${{ vars.EHOSCTL_CA_PEM }}"
      refute inspect(preview) =~ "secrets.EHOS_TOKEN"

      runs = Enum.map(preview["steps"], &(&1["run"] || ""))
      install = Enum.find(runs, &(&1 =~ "gh release download v0.28.0"))

      # The binary runs only once its SHA-256 is the release's: ehos-tools' release v0.28.0,
      # SHA256SUMS, `ehosctl_linux_x64`.
      assert install =~
               "ba806afa5eb8112523b51e715342db11d54d3715b06e7f62911ede22cf500bab  $RUNNER_TEMP/ehosctl_linux_x64"

      assert :binary.match(install, "sha256sum --check --strict") <
               :binary.match(install, "install -m 0755")

      assert Enum.any?(runs, &(&1 =~ ~s|env extend "$environment" --app "$APPLICATION" --ttl 8h|))
      assert Enum.any?(runs, &(&1 =~ ~s|env create "$environment" --app "$APPLICATION" --ttl 8h|))
      assert Enum.any?(runs, &(&1 =~ ~s|environment="$APPLICATION-pr-$PULL_REQUEST"|))
      assert Enum.any?(runs, &(&1 =~ "<!-- ehos-preview %s %s -->"))
      assert Enum.any?(runs, &(&1 =~ ~S|"$APPLICATION" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$|))
      # The job's credential cannot register the application, so naming no installation says a
      # person registers it there once.
      no_installation = Enum.find(runs, &(&1 =~ "ehosctl apps register <manifest>"))
      {register, _} = :binary.match(no_installation, "ehosctl apps register")
      {variable, _} = :binary.match(no_installation, "Then set the repository variable")
      assert register < variable

      remove = jobs["preview-remove"]

      assert remove["if"] =~ "github.event.action == 'closed'"
      assert remove["if"] =~ same_repository
      assert remove["permissions"]["id-token"] == "write"
      refute Map.has_key?(remove, "needs")

      remove_runs = Enum.map(remove["steps"], &(&1["run"] || ""))

      # Only the bot's own comment, naming this pull request's environment, says what to remove.
      assert Enum.any?(remove_runs, &(&1 =~ ~s|.user.login == "github-actions[bot]"|))
      assert Enum.any?(remove_runs, &(&1 =~ ~s|"$application-pr-$PULL_REQUEST"|))

      removal =
        Enum.find_index(
          remove_runs,
          &(&1 =~ ~s|env remove "$ENVIRONMENT" --app "$APPLICATION" --confirm "$ENVIRONMENT"|)
        )

      assert removal

      # Once the environment is removed, the preview's comment says so, and no longer links an
      # address nothing answers (ehos-tools#295). It keeps its marker, for a pull request opened
      # again.
      assert remove["permissions"]["pull-requests"] == "write"
      assert Enum.any?(remove_runs, &(&1 =~ ~s|echo "comment=$comment" >> "$GITHUB_OUTPUT"|))
      said = Enum.find_index(remove_runs, &(&1 =~ "**Preview:** removed"))
      assert said > removal
      assert Enum.at(remove_runs, said) =~ "<!-- ehos-preview %s %s -->"
      assert Enum.at(remove_runs, said) =~ ~s|issues/comments/$ID|
      refute Enum.at(remove_runs, said) =~ "https://"
      # Also when the removal failed or never ran, as for a preview that expired first: it then
      # says it expires by itself.
      step = Enum.at(remove["steps"], said)
      assert step["if"] =~ "always()"
      assert step["env"]["REMOVED"] == "${{ steps.remove.outcome }}"
      script = Enum.at(remove_runs, said)

      # A merge's closing run is on the base branch's ref, for which EHOS gives no credential to
      # remove a preview (eh-os#672): it tries nothing that needs one, and says the preview was
      # kept, before anything about a removal.
      merge_skips = "steps.preview.outputs.environment != '' && !github.event.pull_request.merged"

      for id <- ["ehosctl-release", "remove"] do
        assert Enum.find(remove["steps"], &(&1["id"] == id))["if"] == merge_skips
      end

      assert Enum.find(remove["steps"], &(&1["name"] == "Install ehosctl 0.23.0"))["if"] ==
               merge_skips

      assert step["env"]["MERGED"] == "${{ github.event.pull_request.merged }}"
      {merged, _} = :binary.match(script, ~s|if [ "$MERGED" = true ]; then|)
      {kept, _} = :binary.match(script, "**Preview:** kept when this pull request was merged")
      {success, _} = :binary.match(script, ~s|elif [ "$REMOVED" = success ]; then|)
      assert merged < kept and kept < success

      {removed, _} = :binary.match(script, "**Preview:** removed")
      {otherwise, _} = :binary.match(script, "else")
      {not_removed, _} = :binary.match(script, "**Preview:** not removed")
      assert success < removed and removed < otherwise and otherwise < not_removed
      assert Enum.at(remove["steps"], removal)["id"] == "remove"
    end

    # Every build `publish` pushes, on `main` and on a pull request, is registered with EHOS with
    # the commit it came from, and a pull request's preview is that build (eh-os D-146,
    # ehos-tools#554).
    test "registers each build it publishes, and deploys the pull request's preview from it" do
      workflow =
        installed() |> content(".github/workflows/ci.yml") |> YamlElixir.read_from_string!()

      publish = workflow["jobs"]["publish"]
      steps = publish["steps"]
      at = fn step -> Enum.find_index(steps, &(&1 == step)) end

      assert workflow["on"]["push"]["branches"] == ["main"]

      assert publish["permissions"] == %{
               "contents" => "read",
               "packages" => "write",
               "id-token" => "write"
             }

      assert publish["env"]["EHOSCTL_URL"] == "${{ vars.EHOSCTL_URL }}"

      assert publish["outputs"] == %{
               "application" => "${{ steps.register.outputs.application }}",
               "build" => "${{ steps.register.outputs.build }}"
             }

      # `ehosctl builds register` reads 100 commits before the one built: a pull request's is
      # GitHub's test merge, one above its head (ehos-tools#498). The checkout comes first, since it
      # empties a workspace that is not a repository, and leaves no token behind.
      [checkout | _rest] = steps
      assert checkout["uses"] =~ ~r/^actions\/checkout@[0-9a-f]{40}$/

      assert checkout["with"] == %{
               "fetch-depth" => "${{ github.event_name == 'pull_request' && 102 || 101 }}",
               "persist-credentials" => false
             }

      bundle = Enum.find(steps, &(&1["with"]["name"] == "ehos-bundle"))
      assert bundle["with"]["path"] == "ehos-deployment/ehos.bundle"
      upload = Enum.find(steps, &(&1["with"]["name"] == "ehos-deployment"))
      index = Enum.find(steps, &(&1["id"] == "index"))
      install = Enum.find(steps, &(&1["name"] == "Install ehosctl 0.28.0"))
      register = Enum.find(steps, &(&1["id"] == "register"))

      assert install["run"] =~
               "ba806afa5eb8112523b51e715342db11d54d3715b06e7f62911ede22cf500bab  $RUNNER_TEMP/ehosctl_linux_x64"

      # Registered after the index is pushed and `ehos-deployment` published, so a refusal
      # leaves the artifact as it was, and only where the repository names its installation.
      assert at.(index) < at.(bundle) and at.(bundle) < at.(upload) and
               at.(upload) < at.(register)

      for step <- [install, register],
          do: assert(step["if"] == "vars.EHOSCTL_URL != ''")

      assert register["env"]["DIGEST"] == "${{ steps.index.outputs.digest }}"
      script = register["run"]

      assert script =~
               ~s|ehosctl builds register ehos-deployment/ehos.bundle --image "$IMAGE@$DIGEST" --json > "$RUNNER_TEMP/build.json" 2> "$RUNNER_TEMP/register.err" \|\| code=$?|

      assert script =~ ~S|"$application" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$|

      # The id reaches `$GITHUB_OUTPUT` and `preview` only in its form: `jq` prints `null` for a
      # missing one.
      {id, _} =
        :binary.match(script, ~S|build=$(jq -r '.build.id // empty' "$RUNNER_TEMP/build.json")|)

      {form, _} =
        :binary.match(script, ~S|if ! [[ "$build" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$ ]]; then|)

      {output, _} = :binary.match(script, ~s|echo "build=$build" >> "$GITHUB_OUTPUT"|)
      assert id < form and form < output

      # EHOS refusing the token on a push, as a trust made for previews alone does, leaves `main`
      # as it was before builds, and says how to add the ref, keeping the trust's others, once
      # the ref is protected. A refused registration, a pull request's refusal and any other
      # failure fail the job.
      {refused, _} =
        :binary.match(
          script,
          ~s|elif [ "$code" = 3 ] && [ "$GITHUB_EVENT_NAME" = push ] &&\n| <>
            ~S{     jq -e '.error.message | test("^\\S+ refused this job.s GitHub Actions token\\. ")' "$RUNNER_TEMP/register.err" > /dev/null 2>&1; then}
        )

      {protect, _} = :binary.match(script, "first protect the ref with a ruleset")

      {trust, _} =
        :binary.match(
          script,
          "--ref 'refs/pull/*/merge' --ref $GITHUB_REF\\`, with every other ref"
        )

      {otherwise, _} = :binary.match(script, ~s|exit "$code"|)
      assert refused < protect and protect < trust and trust < otherwise

      setup = Enum.find(steps, &((&1["uses"] || "") =~ ~r/^docker\/setup-buildx-action@/))
      assert setup["with"] == %{"driver" => "docker"}

      preview = workflow["jobs"]["preview"]

      assert preview["env"]["APPLICATION"] == "${{ needs.publish.outputs.application }}"
      assert preview["env"]["BUILD"] == "${{ needs.publish.outputs.build }}"
      refute Enum.any?(preview["steps"], &(&1["with"]["name"] == "ehos-deployment"))

      runs = Enum.map(preview["steps"], &(&1["run"] || ""))
      deploy = Enum.find(runs, &(&1 =~ "ehosctl deploy"))

      assert deploy ==
               ~s|code=0\nehosctl deploy "$APPLICATION" --env "$ENVIRONMENT" --json --build "$BUILD" > deployment.json \|\| code=$?\ncat deployment.json\n| <>
                 ~s|echo "address=$(jq -r '.addresses[0] // empty' deployment.json 2> /dev/null)" >> "$GITHUB_OUTPUT"\n| <>
                 ~s|echo "outcome=$(jq -r '.outcome // empty' deployment.json 2> /dev/null)" >> "$GITHUB_OUTPUT"\n| <>
                 ~s|exit "$code"\n|

      assert Enum.any?(runs, &(&1 =~ ~s|if [ -z "$BUILD" ]; then|))
    end

    # A workflow of its own, so that editing the description reruns this job alone (ehos-tools#229).
    test "checks in a workflow of its own, rerun when the description is edited, that the pull request records its review" do
      workflow =
        installed() |> content(".github/workflows/review.yml") |> YamlElixir.read_from_string!()

      assert workflow["on"]["pull_request"]["types"] == ~w(opened edited reopened synchronize)
      assert [job] = Map.values(workflow["jobs"])
      assert job["env"]["MIX_ENV"] == "dev"

      runs = Enum.map(job["steps"], &(&1["run"] || ""))
      check = Enum.find(job["steps"], &(&1["run"] == "mix ehos_app.review pull_request"))

      # `ehos_app` is a dependency in `:dev` alone.
      assert Enum.find_index(runs, &(&1 == "mix deps.get --only dev --check-locked")) <
               Enum.find_index(runs, &(&1 == "mix ehos_app.review pull_request"))

      # The description comes in through the environment, never the script's text.
      assert check["env"]["PULL_REQUEST_BODY"] == "${{ github.event.pull_request.body }}"
      refute Enum.any?(runs, &(&1 =~ "github.event.pull_request"))

      token = Enum.find(job["steps"], &(&1["id"] == "private-deps"))
      assert token["with"]["repositories"] == "eh-os-contract,ehos-tools"
      assert token["with"]["permission-contents"] == "read"

      # A run that fails on the description, as the first usually does, still keeps its build.
      save = Enum.find(job["steps"], &(&1["uses"] == "actions/cache/save@v6"))
      assert save["if"] =~ "!cancelled()"
      assert save["if"] =~ "steps.cache.outputs.cache-hit != 'true'"
      restore = Enum.find(job["steps"], &(&1["id"] == "cache"))
      assert restore["uses"] == "actions/cache/restore@v6"
      assert restore["with"]["key"] == save["with"]["key"]
    end
  end
end
