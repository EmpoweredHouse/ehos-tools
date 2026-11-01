defmodule Mix.Tasks.EhosApp.InstallTest.CI do
  use Mix.Tasks.EhosApp.InstallCase, async: true

  # The check job's steps, each by its name, else its id, its action or its command.
  @check_steps [
    "Check the App's secrets are set",
    "actions/checkout@v7",
    "jdx/mise-action@v4",
    "ehosctl-release",
    "Install ehosctl",
    "actions/cache@v6",
    "ikalnytskyi/action-setup-postgres@v8",
    "private-deps",
    "mix local.hex --force",
    "mix deps.get",
    "Check ehosctl is ${{ env.PINNED_EHOSCTL_VERSION }}'s binary",
    "mise exec -- ehosctl verify",
    "Check ehosctl verify wrote the bundle",
    "actions/upload-artifact@v7"
  ]

  # The check job's fetch of the test environment's dependencies, the token in its environment
  # alone.
  @deps_get ~S'''
  name: mix deps.get
  env:
    GIT_CONFIG_COUNT: "2"
    GIT_CONFIG_KEY_0: url.https://x-access-token:${{ steps.private-deps.outputs.token }}@github.com/EmpoweredHouse/eh-os-contract.insteadOf
    GIT_CONFIG_VALUE_0: https://github.com/EmpoweredHouse/eh-os-contract
    GIT_CONFIG_KEY_1: url.https://x-access-token:${{ steps.private-deps.outputs.token }}@github.com/EmpoweredHouse/ehos-tools.insteadOf
    GIT_CONFIG_VALUE_1: https://github.com/EmpoweredHouse/ehos-tools
  run: mix deps.get --only test --check-locked
  '''

  # The token for EHOS's two private repositories, in `check` and in `image`.
  @private_deps ~S'''
  id: private-deps
  uses: actions/create-github-app-token@v3
  with:
    app-id: ${{ secrets.EHOS_CI_APP_ID }}
    private-key: ${{ secrets.EHOS_CI_APP_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}
    repositories: eh-os-contract,ehos-tools
    permission-contents: read
  '''

  describe "CI" do
    test "gates the project with ehosctl verify, then builds the image by digest beside the bundle" do
      workflow = workflow()
      check = workflow["jobs"]["check"]["steps"]

      # The gates are `ehosctl verify`'s alone, not listed again here, where they could drift
      # from what a developer runs; the `ehosctl` it pins runs the schema check too. The
      # dependencies are fetched first, with the token, so `verify`'s own fetch needs none.
      assert outline(check) == @check_steps

      assert step(check, "run", "mise exec -- ehosctl verify") == %{
               "run" => "mise exec -- ehosctl verify"
             }

      # The bundle `verify` writes, the manifest and every graph document with `bundle.json`
      # (eh-os D-146), is the artifact, and nothing beside it. With an `eh_os_contract` before
      # its bundle task, `verify` writes the manifest alone, and the job stops there, saying why,
      # rather than uploading a manifest EHOS cannot register as a build (ehos-tools#520).
      assert step(check, "name", "Check ehosctl verify wrote the bundle") ==
               yaml(~S'''
               name: Check ehosctl verify wrote the bundle
               run: |
                 if [ ! -f _build/ehos.bundle/bundle.json ]; then
                   echo "::error::ehosctl verify wrote no bundle into _build/ehos.bundle/: this project's eh_os_contract has no mix eh_os_contract.bundle, which eh-os-contract has from v0.12.0. Running mix ehos_app.install again moves a pin an earlier ehos_app wrote; move one of your own by hand."
                   exit 1
                 fi
               ''')

      assert step(check, "uses", "actions/upload-artifact@v7") ==
               yaml(~S'''
               uses: actions/upload-artifact@v7
               with:
                 name: ehos-bundle
                 path: _build/ehos.bundle
                 if-no-files-found: error
               ''')

      image = workflow["jobs"]["image"]

      assert Map.take(image, ["needs", "permissions"]) == %{
               "needs" => "check",
               "permissions" => %{"contents" => "read", "packages" => "write"}
             }

      assert step(image["steps"], "id", "build") ==
               yaml(~S'''
               id: build
               uses: docker/build-push-action@v7
               with:
                 context: .
                 platforms: ${{ matrix.platform }}
                 labels: ${{ steps.meta.outputs.labels }}
                 outputs: type=image,name=${{ steps.name.outputs.image }},push-by-digest=true,name-canonical=true,push=${{ (github.event_name == 'push' || (github.event.pull_request.head.repo.full_name == github.repository && !endsWith(github.actor, '[bot]') && vars.EHOSCTL_URL != '')) }}
                 secrets: github_token=${{ steps.private-deps.outputs.token }}
               ''')

      publish = workflow["jobs"]["publish"]

      assert Map.take(publish, ["needs", "permissions"]) == %{
               "needs" => "image",
               "permissions" => %{
                 "contents" => "read",
                 "packages" => "write",
                 "id-token" => "write"
               }
             }

      assert step(publish["steps"], "id", "index") ==
               yaml(~S'''
               id: index
               working-directory: digests
               env:
                 IMAGE: ${{ steps.name.outputs.image }}
                 TAG: ${{ steps.meta.outputs.version }}
               run: |
                 sources=()
                 for digest in *; do sources+=("$IMAGE@sha256:$digest"); done
                 docker buildx imagetools create --tag "$IMAGE:$TAG" "${sources[@]}"
                 digest=$(docker buildx imagetools inspect "$IMAGE:$TAG" --format '{{json .Manifest}}' | jq -r .digest)
                 echo "digest=$digest" >> "$GITHUB_OUTPUT"
               ''')

      assert step(publish["steps"], "run", ~S|echo "${IMAGE}@${DIGEST}" > ehos-deployment/image|) ==
               yaml(~S'''
               env:
                 IMAGE: ${{ steps.name.outputs.image }}
                 DIGEST: ${{ steps.index.outputs.digest }}
               run: echo "${IMAGE}@${DIGEST}" > ehos-deployment/image
               ''')
    end

    test "reads EHOS's two private repositories, and nothing else, with the App's token" do
      jobs = workflow()["jobs"]

      for job <- ["check", "image"] do
        assert step(jobs[job]["steps"], "id", "private-deps") == yaml(@private_deps), job
      end

      assert step(jobs["check"]["steps"], "name", "mix deps.get") == yaml(@deps_get)
    end

    # mise installs `ehosctl` from a private repository's releases, asking for their
    # attestations first: the token reads ehos-tools alone, with both permissions, only the step
    # that installs sees it, and that step comes before any dependency's code runs. The binary
    # runs only once it is checked against the SHA-256 its release published, since a release's
    # asset can be replaced under the same tag.
    test "installs the released ehosctl with mise, with a token that step alone sees, and checks it" do
      steps = workflow()["jobs"]["check"]["steps"]

      assert step(steps, "id", "ehosctl-release") ==
               yaml(~S'''
               id: ehosctl-release
               uses: actions/create-github-app-token@v3
               with:
                 app-id: ${{ secrets.EHOS_CI_APP_ID }}
                 private-key: ${{ secrets.EHOS_CI_APP_PRIVATE_KEY }}
                 owner: ${{ github.repository_owner }}
                 repositories: ehos-tools
                 permission-contents: read
                 permission-attestations: read
               ''')

      install = step(steps, "name", "Install ehosctl")

      assert install ==
               yaml(~S'''
               name: Install ehosctl
               env:
                 MISE_GITHUB_TOKEN: ${{ steps.ehosctl-release.outputs.token }}
               run: mise use -g "github:EmpoweredHouse/ehos-tools@$PINNED_EHOSCTL_VERSION"
               ''')

      assert for(step <- steps, inspect(step) =~ "steps.ehosctl-release.outputs.token", do: step) ==
               [install]

      assert for(step <- steps, Map.has_key?(step["env"] || %{}, "MISE_GITHUB_TOKEN"), do: step) ==
               [install]

      assert step(steps, "name", "Check ehosctl is ${{ env.PINNED_EHOSCTL_VERSION }}'s binary") ==
               yaml(~S'''
               name: Check ehosctl is ${{ env.PINNED_EHOSCTL_VERSION }}'s binary
               run: |
                 echo "$PINNED_EHOSCTL_SHA256  $(mise which ehosctl)" |
                   sha256sum --check --strict -
               ''')

      assert outline(steps) == @check_steps
    end

    # The workflow names the `ehosctl` it runs once, so a later `ehos_app` moves every job to a
    # later one by two values: each install reads the release `PINNED_EHOSCTL_VERSION` names, each
    # check the SHA-256 `PINNED_EHOSCTL_SHA256` names, and no job or step sets either of its own,
    # so no job can run another `ehosctl`.
    test "names the ehosctl every job runs, and its SHA-256, once" do
      text = content(installed(), ".github/workflows/ci.yml")
      workflow = YamlElixir.read_from_string!(text)
      %{"PINNED_EHOSCTL_VERSION" => version, "PINNED_EHOSCTL_SHA256" => sha256} = workflow["env"]

      assert Map.keys(workflow["env"]) == ["PINNED_EHOSCTL_SHA256", "PINNED_EHOSCTL_VERSION"]
      assert {:ok, %Version{pre: []}} = Version.parse(to_string(version))
      assert sha256 =~ ~r/\A[0-9a-f]{64}\z/
      assert {occurrences(text, version), occurrences(text, sha256)} == {1, 1}

      steps = for {_, job} <- workflow["jobs"], step <- job["steps"], do: step

      envs =
        Enum.map(workflow["jobs"], fn {_, job} -> job["env"] end) ++ Enum.map(steps, & &1["env"])

      runs = for step <- steps, step["run"], do: step["run"]

      # Neither in an `env:` of a job or a step, nor through `$GITHUB_ENV` or a command's prefix.
      assert for(env <- envs, env, key <- Map.keys(env), key =~ "PINNED_EHOSCTL", do: key) == []
      assert for(run <- runs, run =~ ~r/PINNED_EHOSCTL_\w*=/, do: run) == []

      ehosctl =
        Enum.filter(
          runs,
          &(&1 =~
              ~r{ehos-tools@|EmpoweredHouse/ehos-tools/releases|(-R|--repo) EmpoweredHouse/ehos-tools})
        )

      checks = Enum.filter(runs, &(&1 =~ "sha256sum" and &1 =~ "ehosctl"))

      assert {Enum.map(
                ehosctl,
                &(&1 =~
                    ~r/ehos-tools@\$PINNED_EHOSCTL_VERSION\b|download "v\$PINNED_EHOSCTL_VERSION"/)
              ), Enum.map(checks, &(&1 =~ ~S|echo "$PINNED_EHOSCTL_SHA256 |))} ==
               {[true, true, true, true], [true, true, true, true]}
    end

    # `mix deps.get` prints a package's advisories and exits 0 (ehos-tools#507). `ehosctl verify`
    # audits them from 0.29.0 on, and the job pins a later one, so no step of its own does it
    # twice.
    test "fails on a retired or vulnerable package through ehosctl verify alone" do
      steps = workflow()["jobs"]["check"]["steps"]

      assert outline(steps) == @check_steps
      assert for(step <- steps, inspect(step) =~ "hex.audit", do: step) == []
    end

    # An image for amd64 alone does not start on Apple silicon, where Erlang/OTP fails under
    # x86-64 emulation, nor on an arm64 cluster.
    test "builds the image natively for amd64 and arm64, and deploys one index over both" do
      image = workflow()["jobs"]["image"]

      assert Map.take(image, ["strategy", "runs-on"]) == %{
               "strategy" => %{
                 "matrix" => %{
                   "include" => [
                     %{
                       "runner" => "ubuntu-24.04",
                       "platform" => "linux/amd64",
                       "arch" => "amd64"
                     },
                     %{
                       "runner" => "ubuntu-24.04-arm",
                       "platform" => "linux/arm64",
                       "arch" => "arm64"
                     }
                   ]
                 }
               },
               "runs-on" => "${{ matrix.runner }}"
             }
    end

    # With the test environment's dependencies alone, `deps.unlock --check-unused` reports the
    # children of dev-only ones as unused, and fails every run.
    test "fetches the test environment's dependencies alone, and checks nothing that needs the rest" do
      steps = workflow()["jobs"]["check"]["steps"]

      assert step(steps, "name", "mix deps.get") == yaml(@deps_get)
      assert outline(steps) == @check_steps
    end

    # A pull request of the repository gets a preview of its own on EHOS, with no stored secret
    # (eh-os D-110, ehos-tools T-18, ehos-tools#266); a fork's and a bot's get none, and the
    # environment goes when the pull request closes.
    test "deploys a pull request of the repository to an ephemeral environment of its own, links it, and removes it when it closes" do
      workflow = workflow()
      jobs = workflow["jobs"]

      assert workflow["on"]["pull_request"] == %{
               "types" => ["opened", "synchronize", "reopened", "closed"]
             }

      # One group per pull request, whose closing waits for its run rather than cancelling it: a
      # merged pull request's closing runs on the base branch's ref, which every one shares.
      assert workflow["concurrency"] == %{
               "group" => "ci-${{ github.event.pull_request.number || github.ref }}",
               "cancel-in-progress" =>
                 "${{ github.event_name == 'pull_request' && github.event.action != 'closed' }}"
             }

      assert jobs["check"]["if"] == "github.event.action != 'closed'"

      # A pull request of the repository pushes its image and publishes it, as `main` does, where
      # the repository names its installation.
      assert step(jobs["image"]["steps"], "id", "build")["with"]["outputs"] ==
               "type=image,name=${{ steps.name.outputs.image }},push-by-digest=true,name-canonical=true," <>
                 "push=${{ (github.event_name == 'push' || (github.event.pull_request.head.repo.full_name == github.repository && !endsWith(github.actor, '[bot]') && vars.EHOSCTL_URL != '')) }}"

      assert jobs["publish"]["if"] ==
               "(github.event_name == 'push' || (github.event.pull_request.head.repo.full_name == github.repository && !endsWith(github.actor, '[bot]') && vars.EHOSCTL_URL != ''))"

      # The actions a job that may ask for a token EHOS accepts runs are pinned by commit.
      assert Map.new(["publish", "preview", "preview-remove"], fn job ->
               {job, for(%{"uses" => uses} <- jobs[job]["steps"], do: uses)}
             end) == %{
               "publish" => [
                 "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
                 "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333",
                 "docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069",
                 "docker/login-action@81c6f93d4bc991e510b342a00b419b3bb4efc5c6",
                 "docker/metadata-action@dc802804100637a589fabce1cb79ff13a1411302",
                 "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333",
                 "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9",
                 "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510"
               ],
               "preview" => [
                 "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510"
               ],
               "preview-remove" => [
                 "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510"
               ]
             }

      # The installation is two repository variables, not secrets. Without one `publish` is
      # skipped, and `preview` still runs to say so: the job's credential cannot register the
      # application, so it says a person registers it there once. The binary runs only once its
      # SHA-256 is the one `PINNED_EHOSCTL_SHA256` names.
      assert jobs["preview"] ==
               yaml(~S'''
               needs: publish
               if: >-
                 !cancelled() &&
                 github.event_name == 'pull_request' && github.event.action != 'closed' &&
                 github.event.pull_request.head.repo.full_name == github.repository &&
                 !endsWith(github.actor, '[bot]') &&
                 (needs.publish.result == 'success' || vars.EHOSCTL_URL == '')
               runs-on: ubuntu-24.04
               permissions:
                 contents: read
                 id-token: write
                 pull-requests: write
               env:
                 EHOSCTL_URL: ${{ vars.EHOSCTL_URL }}
                 EHOSCTL_CA_PEM: ${{ vars.EHOSCTL_CA_PEM }}
                 PULL_REQUEST: ${{ github.event.pull_request.number }}
                 HEAD: ${{ github.event.pull_request.head.sha }}
                 APPLICATION: ${{ needs.publish.outputs.application }}
                 BUILD: ${{ needs.publish.outputs.build }}
               defaults:
                 run:
                   shell: bash
               steps:
                 - id: installation
                   name: The installation
                   run: |
                     if [ -z "$EHOSCTL_URL" ]; then
                       {
                         echo "No preview: this repository names no EHOS installation. Register the application there"
                         echo "once, with \`ehosctl apps register <manifest>\` and \`ehos.application.register\` on the"
                         echo "platform, and trust this repository: \`ehosctl trust add --app <application> --repo"
                         echo "${GITHUB_REPOSITORY} --ref 'refs/pull/*/merge'\`. Then set the repository variable"
                         echo "\`EHOSCTL_URL\` to its address, and \`EHOSCTL_CA_PEM\` to its CA certificate if it has its"
                         echo "own. DEVELOPMENT.md, \"Previews of pull requests\", has the commands."
                       } >> "$GITHUB_STEP_SUMMARY"
                       echo "named=false" >> "$GITHUB_OUTPUT"
                       exit 0
                     fi
                     echo "named=true" >> "$GITHUB_OUTPUT"
                     if [ -n "$EHOSCTL_CA_PEM" ]; then
                       printf '%s\n' "$EHOSCTL_CA_PEM" > "$RUNNER_TEMP/ehos-ca.pem"
                       echo "EHOSCTL_CA_FILE=$RUNNER_TEMP/ehos-ca.pem" >> "$GITHUB_ENV"
                     fi
                 - if: steps.installation.outputs.named == 'true'
                   id: ehosctl-release
                   uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510 # v3.3.0
                   with:
                     app-id: ${{ secrets.EHOS_CI_APP_ID }}
                     private-key: ${{ secrets.EHOS_CI_APP_PRIVATE_KEY }}
                     owner: ${{ github.repository_owner }}
                     repositories: ehos-tools
                     permission-contents: read
                 - if: steps.installation.outputs.named == 'true'
                   name: Install ehosctl ${{ env.PINNED_EHOSCTL_VERSION }}
                   env:
                     GH_TOKEN: ${{ steps.ehosctl-release.outputs.token }}
                   run: |
                     gh release download "v$PINNED_EHOSCTL_VERSION" --repo EmpoweredHouse/ehos-tools --pattern ehosctl_linux_x64 --dir "$RUNNER_TEMP"
                     echo "$PINNED_EHOSCTL_SHA256  $RUNNER_TEMP/ehosctl_linux_x64" | sha256sum --check --strict -
                     install -m 0755 "$RUNNER_TEMP/ehosctl_linux_x64" /usr/local/bin/ehosctl
                     ehosctl --version
                 - if: steps.installation.outputs.named == 'true'
                   id: environment
                   name: Make or extend the environment
                   run: |
                     if ! [[ "$APPLICATION" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
                       echo "::error::The manifest names no application that is a DNS label: '$APPLICATION'"
                       exit 1
                     fi
                     if [ -z "$BUILD" ]; then
                       echo "::error::publish registered no build in this run, so there is nothing to deploy."
                       exit 1
                     fi
                     environment="$APPLICATION-pr-$PULL_REQUEST"
                     echo "ENVIRONMENT=$environment" >> "$GITHUB_ENV"
                     # `extend` on every push but the first, where it finds none, and `create` then.
                     ehosctl env extend "$environment" --app "$APPLICATION" --ttl 8h 2> extend.err ||
                       { cat extend.err; ehosctl env create "$environment" --app "$APPLICATION" --ttl 8h; }
                 - if: steps.environment.outcome == 'success'
                   id: comment
                   name: Say on the pull request that the preview is being deployed
                   env:
                     GH_TOKEN: ${{ github.token }}
                   run: |
                     comments="repos/$GITHUB_REPOSITORY/issues/$PULL_REQUEST/comments"
                     filter='.[] | select(.user.login == "github-actions[bot]")'
                     filter="$filter | select(.body | startswith(\"<!-- ehos-preview \")) | .id"
                     id=$(gh api --paginate "$comments" --jq "$filter" | sed -n 1p)
                     body=$(printf '<!-- ehos-preview %s %s -->\n**Preview:** deploying %s to the ephemeral environment `%s`…\n' \
                       "$ENVIRONMENT" "$APPLICATION" "$HEAD" "$ENVIRONMENT")
                     if [ -n "$id" ]; then
                       gh api --method PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$id" -f body="$body" > /dev/null
                     else
                       id=$(gh api --method POST "$comments" -f body="$body" --jq .id)
                     fi
                     echo "id=$id" >> "$GITHUB_OUTPUT"
                 - if: steps.environment.outcome == 'success'
                   id: deploy
                   name: Deploy the candidate
                   run: |
                     code=0
                     ehosctl deploy "$APPLICATION" --env "$ENVIRONMENT" --json --build "$BUILD" > deployment.json || code=$?
                     cat deployment.json
                     echo "address=$(jq -r '.addresses[0] // empty' deployment.json 2> /dev/null)" >> "$GITHUB_OUTPUT"
                     echo "outcome=$(jq -r '.outcome // empty' deployment.json 2> /dev/null)" >> "$GITHUB_OUTPUT"
                     exit "$code"
                 - if: always() && steps.comment.outcome == 'success'
                   name: Link the preview on the pull request
                   env:
                     GH_TOKEN: ${{ github.token }}
                     ID: ${{ steps.comment.outputs.id }}
                     ADDRESS: ${{ steps.deploy.outputs.address }}
                     OUTCOME: ${{ steps.deploy.outputs.outcome }}
                   run: |
                     if [ "$OUTCOME" = active ]; then
                       said="**Preview:** ${ADDRESS:-active, not served at an address}, in the ephemeral environment \`$ENVIRONMENT\`, from $HEAD."
                     elif [ "$OUTCOME" = not_followed ]; then
                       said="**Preview:** $HEAD was deployed to \`$ENVIRONMENT\`; whether it became active is on the application's page in EHOS's console."
                     else
                       said="**Preview:** the deployment of $HEAD to \`$ENVIRONMENT\` did not become active (${OUTCOME:-no outcome}); the run's log says why."
                     fi
                     body=$(printf '<!-- ehos-preview %s %s -->\n%s It expires eight hours after the last push, if closing this pull request has not removed it first.\n' \
                       "$ENVIRONMENT" "$APPLICATION" "$said")
                     gh api --method PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$ID" -f body="$body" > /dev/null
               ''')

      # Only the bot's own comment, naming this pull request's environment, says what to remove.
      # Once the environment is removed, the preview's comment says so, and no longer links an
      # address nothing answers (ehos-tools#295). It keeps its marker, for a pull request opened
      # again. Also when the removal failed or never ran, as for a preview that expired first: it
      # then says it expires by itself. A merge's closing run is on the base branch's ref, for
      # which EHOS gives no credential to remove a preview (eh-os#672): it tries nothing that
      # needs one, and says the preview was kept, before anything about a removal.
      assert jobs["preview-remove"] ==
               yaml(~S'''
               if: >-
                 github.event_name == 'pull_request' && github.event.action == 'closed' &&
                 github.event.pull_request.head.repo.full_name == github.repository &&
                 !endsWith(github.actor, '[bot]') && vars.EHOSCTL_URL != ''
               runs-on: ubuntu-24.04
               permissions:
                 contents: read
                 id-token: write
                 pull-requests: write
               env:
                 EHOSCTL_URL: ${{ vars.EHOSCTL_URL }}
                 EHOSCTL_CA_PEM: ${{ vars.EHOSCTL_CA_PEM }}
                 PULL_REQUEST: ${{ github.event.pull_request.number }}
               defaults:
                 run:
                   shell: bash
               steps:
                 - id: preview
                   name: The preview's environment
                   env:
                     GH_TOKEN: ${{ github.token }}
                   run: |
                     filter='.[] | select(.user.login == "github-actions[bot]")'
                     filter="$filter | select(.body | startswith(\"<!-- ehos-preview \"))"
                     filter="$filter | \"\\(.id) \\(.body)\""
                     marker=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PULL_REQUEST/comments" \
                       --jq "$filter" | sed -n 1p)
                     read -r comment _ _ environment application _ <<< "$marker"
                     if [ -n "$environment" ] && [ "$environment" = "$application-pr-$PULL_REQUEST" ] &&
                          [[ "$application" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]] && [[ "$comment" =~ ^[0-9]+$ ]]; then
                       echo "environment=$environment" >> "$GITHUB_OUTPUT"
                       echo "application=$application" >> "$GITHUB_OUTPUT"
                       echo "comment=$comment" >> "$GITHUB_OUTPUT"
                     fi
                     if [ -n "$EHOSCTL_CA_PEM" ]; then
                       printf '%s\n' "$EHOSCTL_CA_PEM" > "$RUNNER_TEMP/ehos-ca.pem"
                       echo "EHOSCTL_CA_FILE=$RUNNER_TEMP/ehos-ca.pem" >> "$GITHUB_ENV"
                     fi
                 - if: steps.preview.outputs.environment != '' && !github.event.pull_request.merged
                   id: ehosctl-release
                   uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510 # v3.3.0
                   with:
                     app-id: ${{ secrets.EHOS_CI_APP_ID }}
                     private-key: ${{ secrets.EHOS_CI_APP_PRIVATE_KEY }}
                     owner: ${{ github.repository_owner }}
                     repositories: ehos-tools
                     permission-contents: read
                 - if: steps.preview.outputs.environment != '' && !github.event.pull_request.merged
                   name: Install ehosctl ${{ env.PINNED_EHOSCTL_VERSION }}
                   env:
                     GH_TOKEN: ${{ steps.ehosctl-release.outputs.token }}
                   run: |
                     gh release download "v$PINNED_EHOSCTL_VERSION" --repo EmpoweredHouse/ehos-tools --pattern ehosctl_linux_x64 --dir "$RUNNER_TEMP"
                     echo "$PINNED_EHOSCTL_SHA256  $RUNNER_TEMP/ehosctl_linux_x64" | sha256sum --check --strict -
                     install -m 0755 "$RUNNER_TEMP/ehosctl_linux_x64" /usr/local/bin/ehosctl
                     ehosctl --version
                 - if: steps.preview.outputs.environment != '' && !github.event.pull_request.merged
                   id: remove
                   name: Remove the environment
                   env:
                     ENVIRONMENT: ${{ steps.preview.outputs.environment }}
                     APPLICATION: ${{ steps.preview.outputs.application }}
                   run: ehosctl env remove "$ENVIRONMENT" --app "$APPLICATION" --confirm "$ENVIRONMENT"
                 - if: always() && steps.preview.outputs.environment != ''
                   name: Say on the pull request what became of the preview
                   env:
                     GH_TOKEN: ${{ github.token }}
                     ENVIRONMENT: ${{ steps.preview.outputs.environment }}
                     APPLICATION: ${{ steps.preview.outputs.application }}
                     ID: ${{ steps.preview.outputs.comment }}
                     MERGED: ${{ github.event.pull_request.merged }}
                     REMOVED: ${{ steps.remove.outcome }}
                   run: |
                     if [ "$MERGED" = true ]; then
                       said="**Preview:** kept when this pull request was merged, on $(date -u +%Y-%m-%d): CI removes no merged pull request's preview. The ephemeral environment \`$ENVIRONMENT\` expires by itself eight hours after the last push, if it has not already, unless someone removes it first with \`ehosctl env remove\`."
                     elif [ "$REMOVED" = success ]; then
                       said="**Preview:** removed with the ephemeral environment \`$ENVIRONMENT\` when this pull request closed, on $(date -u +%Y-%m-%d)."
                     else
                       said="**Preview:** not removed when this pull request closed, on $(date -u +%Y-%m-%d); the run's log says why. The ephemeral environment \`$ENVIRONMENT\` expires by itself eight hours after the last push, if it has not already."
                     fi
                     body=$(printf '<!-- ehos-preview %s %s -->\n%s\n' "$ENVIRONMENT" "$APPLICATION" "$said")
                     gh api --method PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$ID" -f body="$body" > /dev/null
               ''')
    end

    # Every build `publish` pushes, on `main` and on a pull request, is registered with EHOS with
    # the commit it came from, and a pull request's preview is that build (eh-os D-146,
    # ehos-tools#554).
    test "registers each build it publishes, and deploys the pull request's preview from it" do
      workflow = workflow()

      assert workflow["on"]["push"] == %{"branches" => ["main"]}

      # `ehosctl builds register` reads 100 commits before the one built: a pull request's is
      # GitHub's test merge, one above its head (ehos-tools#498). The checkout comes first, since it
      # empties a workspace that is not a repository, and leaves no token behind. The build is
      # registered after the index is pushed and `ehos-deployment` published, so a refusal leaves
      # the artifact as it was, and only where the repository names its installation. The id
      # reaches `$GITHUB_OUTPUT` and `preview` only in its form: `jq` prints `null` for a missing
      # one. EHOS refusing the token on a push leaves `main` as it was before builds, and names the
      # likeliest cause first, an account not linked yet, with `ehosctl github claim` and this run
      # to claim it from (#595); then how to add the ref, keeping the trust's others, once the ref
      # is protected. A refused registration, a pull request's refusal and any other failure fail
      # the job.
      assert workflow["jobs"]["publish"] ==
               yaml(~S'''
               needs: image
               if: (github.event_name == 'push' || (github.event.pull_request.head.repo.full_name == github.repository && !endsWith(github.actor, '[bot]') && vars.EHOSCTL_URL != ''))
               runs-on: ubuntu-24.04
               permissions:
                 contents: read
                 packages: write
                 id-token: write
               env:
                 EHOSCTL_URL: ${{ vars.EHOSCTL_URL }}
                 EHOSCTL_CA_PEM: ${{ vars.EHOSCTL_CA_PEM }}
               outputs:
                 application: ${{ steps.register.outputs.application }}
                 build: ${{ steps.register.outputs.build }}
               defaults:
                 run:
                   shell: bash
               steps:
                 - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
                   with:
                     fetch-depth: ${{ github.event_name == 'pull_request' && 102 || 101 }}
                     persist-credentials: false
                 - id: name
                   run: echo "image=ghcr.io/${GITHUB_REPOSITORY,,}" >> "$GITHUB_OUTPUT"
                 - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
                   with:
                     pattern: digests-*
                     path: digests
                     merge-multiple: true
                 - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1
                   with:
                     driver: docker
                 - uses: docker/login-action@81c6f93d4bc991e510b342a00b419b3bb4efc5c6 # v4.7.0
                   with:
                     registry: ghcr.io
                     username: ${{ github.actor }}
                     password: ${{ github.token }}
                 - id: meta
                   uses: docker/metadata-action@dc802804100637a589fabce1cb79ff13a1411302 # v6.2.0
                   with:
                     images: ${{ steps.name.outputs.image }}
                     tags: type=sha,format=long
                 - id: index
                   working-directory: digests
                   env:
                     IMAGE: ${{ steps.name.outputs.image }}
                     TAG: ${{ steps.meta.outputs.version }}
                   run: |
                     sources=()
                     for digest in *; do sources+=("$IMAGE@sha256:$digest"); done
                     docker buildx imagetools create --tag "$IMAGE:$TAG" "${sources[@]}"
                     digest=$(docker buildx imagetools inspect "$IMAGE:$TAG" --format '{{json .Manifest}}' | jq -r .digest)
                     echo "digest=$digest" >> "$GITHUB_OUTPUT"
                 - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
                   with:
                     name: ehos-bundle
                     path: ehos-deployment/ehos.bundle
                 - env:
                     IMAGE: ${{ steps.name.outputs.image }}
                     DIGEST: ${{ steps.index.outputs.digest }}
                   run: echo "${IMAGE}@${DIGEST}" > ehos-deployment/image
                 - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
                   with:
                     name: ehos-deployment
                     path: ehos-deployment
                     if-no-files-found: error
                 - if: vars.EHOSCTL_URL != ''
                   id: ehosctl-release
                   uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510 # v3.3.0
                   with:
                     app-id: ${{ secrets.EHOS_CI_APP_ID }}
                     private-key: ${{ secrets.EHOS_CI_APP_PRIVATE_KEY }}
                     owner: ${{ github.repository_owner }}
                     repositories: ehos-tools
                     permission-contents: read
                 - if: vars.EHOSCTL_URL != ''
                   name: Install ehosctl ${{ env.PINNED_EHOSCTL_VERSION }}
                   env:
                     GH_TOKEN: ${{ steps.ehosctl-release.outputs.token }}
                   run: |
                     gh release download "v$PINNED_EHOSCTL_VERSION" --repo EmpoweredHouse/ehos-tools --pattern ehosctl_linux_x64 --dir "$RUNNER_TEMP"
                     echo "$PINNED_EHOSCTL_SHA256  $RUNNER_TEMP/ehosctl_linux_x64" | sha256sum --check --strict -
                     install -m 0755 "$RUNNER_TEMP/ehosctl_linux_x64" /usr/local/bin/ehosctl
                     ehosctl --version
                 - if: vars.EHOSCTL_URL != ''
                   id: register
                   name: Register the build
                   env:
                     IMAGE: ${{ steps.name.outputs.image }}
                     DIGEST: ${{ steps.index.outputs.digest }}
                   run: |
                     application=$(jq -r '.application // empty' ehos-deployment/ehos.bundle/ehos.manifest.json)
                     if ! [[ "$application" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
                       echo "::error::The manifest names no application that is a DNS label: '$application'"
                       exit 1
                     fi
                     echo "application=$application" >> "$GITHUB_OUTPUT"
                     if [ -n "$EHOSCTL_CA_PEM" ]; then
                       printf '%s\n' "$EHOSCTL_CA_PEM" > "$RUNNER_TEMP/ehos-ca.pem"
                       export EHOSCTL_CA_FILE="$RUNNER_TEMP/ehos-ca.pem"
                     fi
                     code=0
                     ehosctl builds register ehos-deployment/ehos.bundle --image "$IMAGE@$DIGEST" --json > "$RUNNER_TEMP/build.json" 2> "$RUNNER_TEMP/register.err" || code=$?
                     cat "$RUNNER_TEMP/build.json" "$RUNNER_TEMP/register.err"
                     if [ "$code" = 0 ]; then
                       build=$(jq -r '.build.id // empty' "$RUNNER_TEMP/build.json")
                       if ! [[ "$build" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$ ]]; then
                         echo "::error::EHOS answered with no build id this workflow can use."
                         exit 1
                       fi
                       echo "build=$build" >> "$GITHUB_OUTPUT"
                     elif [ "$code" = 3 ] && [ "$GITHUB_EVENT_NAME" = push ] &&
                          jq -e '.error.message | test("^\\S+ refused this job.s GitHub Actions token\\. ")' "$RUNNER_TEMP/register.err" > /dev/null 2>&1; then
                       echo "::warning::EHOS refused this job's token, so no build was registered. Most likely the GitHub account that started the run is not linked to a person in EHOS yet; otherwise the trust does not accept $GITHUB_REF. The run's summary says what to do for each."
                       {
                         echo "No build registered: EHOS refused this job's token. The publish job's \"Register the build\""
                         echo "step lists every cause; the two likeliest, most likely first:"
                         echo
                         echo "1. The GitHub account that started this run is not linked to a person in EHOS yet. They run"
                         echo "   \`ehosctl github claim <run>\`, with the run \`ehosctl github list\` shows for \`$GITHUB_REPOSITORY\`"
                         echo "   at \`$GITHUB_REF\` (this run: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}),"
                         echo "   or none when it lists that run alone;"
                         echo "   another person holding \`ehos.people.manage\` confirms it, after checking with them that the run"
                         echo "   is theirs (\`ehosctl people github confirm\`). Then rerun this run's jobs, if nothing has"
                         echo "   reached \`$GITHUB_REF\` since: a later run registers a build of its own."
                         echo "2. The trust is made for previews alone, and does not accept \`$GITHUB_REF\`. To have it"
                         echo "   accept \`$GITHUB_REF\`, first protect the ref with a ruleset that lets nothing onto it but a"
                         echo "   merged pull request, with no one allowed to bypass it: a run on it reaches every preview of"
                         echo "   the application, and the trust cannot require the ref to be protected while it accepts pull"
                         echo "   requests. Then someone holding \`ehos.role_binding.manage\` and \`ehos.application.deploy\`"
                         echo "   on $application runs \`ehosctl trust list --app $application\`, and, one right after the"
                         echo "   other, \`ehosctl trust remove <trust> --app $application\` and \`ehosctl trust add --app"
                         echo "   $application --repo ${GITHUB_REPOSITORY} --ref 'refs/pull/*/merge' --ref $GITHUB_REF\`, with"
                         echo "   every other ref, quoted, and every \`--environment\` or \`--workflow\` the list shows. EHOS"
                         echo "   then warns that the trust accepts a branch beside pull requests: the ruleset is the answer"
                         echo "   to that warning."
                         echo
                         echo "\`ehos-deployment\` is published either way."
                       } >> "$GITHUB_STEP_SUMMARY"
                     else
                       exit "$code"
                     fi
               ''')

      preview = workflow["jobs"]["preview"]

      assert Map.take(preview["env"], ["APPLICATION", "BUILD"]) == %{
               "APPLICATION" => "${{ needs.publish.outputs.application }}",
               "BUILD" => "${{ needs.publish.outputs.build }}"
             }

      # No download of `ehos-deployment`: the build EHOS registered is what is deployed.
      assert outline(preview["steps"]) == [
               "The installation",
               "ehosctl-release",
               "Install ehosctl ${{ env.PINNED_EHOSCTL_VERSION }}",
               "Make or extend the environment",
               "Say on the pull request that the preview is being deployed",
               "Deploy the candidate",
               "Link the preview on the pull request"
             ]

      assert step(preview["steps"], "id", "environment") ==
               yaml(~S'''
               if: steps.installation.outputs.named == 'true'
               id: environment
               name: Make or extend the environment
               run: |
                 if ! [[ "$APPLICATION" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
                   echo "::error::The manifest names no application that is a DNS label: '$APPLICATION'"
                   exit 1
                 fi
                 if [ -z "$BUILD" ]; then
                   echo "::error::publish registered no build in this run, so there is nothing to deploy."
                   exit 1
                 fi
                 environment="$APPLICATION-pr-$PULL_REQUEST"
                 echo "ENVIRONMENT=$environment" >> "$GITHUB_ENV"
                 # `extend` on every push but the first, where it finds none, and `create` then.
                 ehosctl env extend "$environment" --app "$APPLICATION" --ttl 8h 2> extend.err ||
                   { cat extend.err; ehosctl env create "$environment" --app "$APPLICATION" --ttl 8h; }
               ''')

      assert step(preview["steps"], "id", "deploy") ==
               yaml(~S'''
               if: steps.environment.outcome == 'success'
               id: deploy
               name: Deploy the candidate
               run: |
                 code=0
                 ehosctl deploy "$APPLICATION" --env "$ENVIRONMENT" --json --build "$BUILD" > deployment.json || code=$?
                 cat deployment.json
                 echo "address=$(jq -r '.addresses[0] // empty' deployment.json 2> /dev/null)" >> "$GITHUB_OUTPUT"
                 echo "outcome=$(jq -r '.outcome // empty' deployment.json 2> /dev/null)" >> "$GITHUB_OUTPUT"
                 exit "$code"
               ''')
    end

    # A workflow of its own, so that editing the description reruns this job alone (ehos-tools#229).
    # `ehos_app` is a dependency in `:dev` alone. The description comes in through the
    # environment, never the script's text. A run that fails on the description, as the first
    # usually does, still keeps its build.
    test "checks in a workflow of its own, rerun when the description is edited, that the pull request records its review" do
      assert workflow(".github/workflows/review.yml") ==
               yaml(~S'''
               name: Review

               on:
                 pull_request:
                   types: [opened, edited, reopened, synchronize]

               permissions:
                 contents: read

               concurrency:
                 group: review-${{ github.ref }}
                 cancel-in-progress: true

               jobs:
                 review-section:
                   name: review section
                   if: github.event.pull_request.user.login != 'dependabot[bot]'
                   runs-on: ubuntu-24.04
                   timeout-minutes: 15
                   env:
                     MIX_ENV: dev
                   steps:
                     - name: Check the App's secrets are set
                       env:
                         APP_ID: ${{ secrets.EHOS_CI_APP_ID }}
                         APP_PRIVATE_KEY: ${{ secrets.EHOS_CI_APP_PRIVATE_KEY }}
                       run: |
                         if [ -z "$APP_ID" ] || [ -z "$APP_PRIVATE_KEY" ]; then
                           echo "::error::Set the repository secrets EHOS_CI_APP_ID and EHOS_CI_APP_PRIVATE_KEY, the ID and private key of the GitHub App that reads eh-os-contract and ehos-tools: https://github.com/EmpoweredHouse/ehos-tools#the-generated-projects-ci. A pull request from a fork gets no secrets."
                           exit 1
                         fi
                     - uses: actions/checkout@v7
                       with:
                         persist-credentials: false
                     - uses: jdx/mise-action@v4
                     - id: cache
                       uses: actions/cache/restore@v6
                       with:
                         path: |
                           deps
                           _build
                         key: review-${{ hashFiles('.tool-versions', 'mix.lock') }}
                     - id: private-deps
                       uses: actions/create-github-app-token@v3
                       with:
                         app-id: ${{ secrets.EHOS_CI_APP_ID }}
                         private-key: ${{ secrets.EHOS_CI_APP_PRIVATE_KEY }}
                         owner: ${{ github.repository_owner }}
                         repositories: eh-os-contract,ehos-tools
                         permission-contents: read
                     - run: mix local.hex --force --if-missing
                     - id: deps
                       name: mix deps.get
                       env:
                         GIT_CONFIG_COUNT: "2"
                         GIT_CONFIG_KEY_0: url.https://x-access-token:${{ steps.private-deps.outputs.token }}@github.com/EmpoweredHouse/eh-os-contract.insteadOf
                         GIT_CONFIG_VALUE_0: https://github.com/EmpoweredHouse/eh-os-contract
                         GIT_CONFIG_KEY_1: url.https://x-access-token:${{ steps.private-deps.outputs.token }}@github.com/EmpoweredHouse/ehos-tools.insteadOf
                         GIT_CONFIG_VALUE_1: https://github.com/EmpoweredHouse/ehos-tools
                       run: mix deps.get --only dev --check-locked
                     - run: mix ehos_app.review pull_request
                       env:
                         PULL_REQUEST_BODY: ${{ github.event.pull_request.body }}
                     - if: ${{ !cancelled() && steps.deps.outcome == 'success' && steps.cache.outputs.cache-hit != 'true' }}
                       uses: actions/cache/save@v6
                       with:
                         path: |
                           deps
                           _build
                         key: review-${{ hashFiles('.tool-versions', 'mix.lock') }}
               ''')
    end

    # Each as that version wrote it, copied from its tag: `ci.yml.eex` takes no assigns.
    for version <-
          ~w(0.2.0 0.2.1 0.3.0 0.5.0 0.6.1 0.8.0 0.15.0 0.16.0 0.17.0 0.18.0 0.19.0 0.22.0
             0.23.0 0.25.0) do
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

    # This version's workflow, with the private repositories' token narrowed to one and a step
    # added: the diff shows both what the developer has and what this version writes.
    test "leaves a workflow the developer changed, with the diff to this version's" do
      changed =
        installed()
        |> content(".github/workflows/ci.yml")
        |> String.replace(
          "repositories: eh-os-contract,ehos-tools",
          "repositories: eh-os-contract",
          global: false
        )
        |> Kernel.<>("      - run: mix dialyzer\n")

      igniter =
        phx_test_project()
        |> Igniter.create_new_file(".github/workflows/ci.yml", changed)
        |> apply_igniter!()
        |> Igniter.compose_task("ehos_app.install", [])

      assert Enum.filter(igniter.notices, &String.starts_with?(&1, ".github/workflows/ci.yml")) ==
               [
                 ~S'''
                 .github/workflows/ci.yml is not what any version of ehos_app wrote, so it is the project's own and
                 was left as it is. This is how it differs from what this version writes (- yours,
                 + this version's); take what applies:

                 ...|
                    |          private-key: ${{ secrets.EHOS_CI_APP_PRIVATE_KEY }}
                    |          owner: ${{ github.repository_owner }}
                  - |          repositories: eh-os-contract
                  + |          repositories: eh-os-contract,ehos-tools
                    |          permission-contents: read
                    |      # The newest Hex, even where mise-action's cache restores an older one with the toolchain:
                 ...|
                    |          body=$(printf '<!-- ehos-preview %s %s -->\n%s\n' "$ENVIRONMENT" "$APPLICATION" "$said")
                    |          gh api --method PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$ID" -f body="$body" > /dev/null
                  - |      - run: mix dialyzer

                 '''
               ]

      assert igniter |> apply_igniter!() |> content(".github/workflows/ci.yml") == changed
    end
  end

  defp workflow(path \\ ".github/workflows/ci.yml"),
    do: installed() |> content(path) |> YamlElixir.read_from_string!()

  defp yaml(text), do: YamlElixir.read_from_string!(text)

  # How often `value` stands in `text` on its own, `v0.31.0` and a sentence's `0.31.0.` among them,
  # but not inside a longer version or hash, as `10.31.0`, `0.31.01` or `0.31.0.1`.
  defp occurrences(text, value),
    do:
      length(Regex.scan(~r/(?<![0-9a-f.])#{Regex.escape(to_string(value))}(?!\.?[0-9a-f])/, text))

  # The first step whose `key` is `value`.
  defp step(steps, key, value), do: Enum.find(steps, &(&1[key] == value))

  # Each step by its name, else its id, its action or its command, in order.
  defp outline(steps), do: Enum.map(steps, &(&1["name"] || &1["id"] || &1["uses"] || &1["run"]))
end
