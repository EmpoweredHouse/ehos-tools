# Set up a repository to release with ehos_release

This page tells a maintainer how to prepare eh-os, ehos-tools or ehos_contract for the release
workflow of `ehos_release`. You make a GitHub App for the repository, keep its key where only
`main` can read it, and protect the release branches and tags. Then you add the files that the
workflow reads, and you call the two workflows. [The README](../README.md) tells how a release
goes.

The steps use `OWNER/REPO` for the repository. Replace it with the name of your repository, such
as `EmpoweredHouse/eh-os`.

## Prerequisites

- You are an administrator of the repository and an owner of its GitHub organization.
- You have the GitHub CLI, `gh`, signed in as that administrator.
- You have [changie](https://changie.dev) 1.26.0, which reads the changelog fragments.

## Make the release App

The App opens the release pull requests and creates the release tags. Each repository has an App
of its own, so that a leaked key gives access to one repository.

1. In the settings of the organization, open **Developer settings**, then **GitHub Apps**, and
   select **New GitHub App**.
2. Name it for the repository, such as *eh-os release*.
3. Clear **Active** under **Webhook**. The App receives no events.
4. Under **Repository permissions**, set **Contents** and **Pull requests** to **Read and write**.
   Give no other permission.
5. Under **Where can this GitHub App be installed?**, select **Only on this account**.
6. Select **Create GitHub App**. Write down the **Client ID** that the page of the App shows.
7. Select **Generate a private key**. GitHub downloads the key as a `.pem` file.
8. Select **Install App**, then **Only select repositories**, and select the one repository.

Without the permission **Workflows**, GitHub refuses a push of the App that changes
`.github/workflows/`. Do not name a file in that directory as a version file of a component.

## Keep the key in the environment release-app

The release workflow reads the key from the environment `release-app` of the repository. Do these
steps in this order. If a workflow names an environment that does not exist, GitHub creates it with
no limit on its branches. A workflow on any branch can read a secret that you add before the limit.

1. Create the environment, limited to branches that you name:

   ```sh
   gh api -X PUT repos/OWNER/REPO/environments/release-app \
     -F 'deployment_branch_policy[protected_branches]=false' \
     -F 'deployment_branch_policy[custom_branch_policies]=true' \
     -F can_admins_bypass=false
   ```

2. Let `main` alone deploy to it:

   ```sh
   gh api -X POST repos/OWNER/REPO/environments/release-app/deployment-branch-policies \
     -f name=main -f type=branch
   ```

3. Read the limit back. No test sees this setting, so check it each time that you change the
   environment. A later change of the environment that leaves out its branch policy or
   `can_admins_bypass` sets them back to their defaults, with no limit.

   ```sh
   gh api repos/OWNER/REPO/environments/release-app --jq '{can_admins_bypass, deployment_branch_policy}'
   gh api repos/OWNER/REPO/environments/release-app/deployment-branch-policies --jq '.branch_policies[] | {name, type}'
   ```

   The first command prints
   `{"can_admins_bypass":false,"deployment_branch_policy":{"custom_branch_policies":true,"protected_branches":false}}`.
   The second prints one line, `{"name":"main","type":"branch"}`.

4. Add the Client ID. `gh` asks for the value:

   ```sh
   gh secret set RELEASE_APP_CLIENT_ID --env release-app --repo OWNER/REPO
   ```

5. Add the private key from the file that GitHub downloaded:

   ```sh
   gh secret set RELEASE_APP_PRIVATE_KEY --env release-app --repo OWNER/REPO < key.pem
   ```

6. Delete the `.pem` file. If you need a key again, generate a new one on the page of the App.

Do not keep the key in a repository secret. A workflow on any branch can read a repository secret.

## Protect the release branches and tags

These rulesets make the App the only author of a release pull request, and an administrator the
only person who can make it a release. Make them in the settings of the repository, under
**Rules**, then **Rulesets**.

1. Make a branch ruleset, *Only the release App pushes release branches*:
   - **Enforcement status**: Active.
   - **Bypass list**: the release App, with the mode **Always**, and nobody else.
   - **Target branches**: the pattern `release/*`.
   - **Rules**: **Restrict creations** and **Restrict updates**. Leave deletions allowed, so that
     GitHub can delete a merged release branch.
2. Make sure that the tag ruleset *Only admins create release tags* exists and is active. It
   restricts creations of the tags `<prefix>*` of each component. Its bypass list has the role
   Repository admin and the release App, both with the mode **Always**. Add the App to no other
   ruleset. Without this ruleset, a person with write access can create a release tag on any
   commit.
3. Make a tag ruleset on the pattern `main` that restricts creations, if the repository has none.
   A tag with the name of a branch can confuse a job that reads the name of a ref.
4. Make sure that the tag ruleset *Release tags stay what they were* is active and restricts
   updates and deletions. It must include the pattern `<prefix>*` of each component exactly, or
   all tags. It must have no exclude pattern that can match a release tag, and its bypass list
   must be empty. A release accepts a pin only to a tag that this ruleset protects, and it does
   not read a narrower pattern, such as `<prefix>[0-9]*`.

Add the prefix of a new component to rulesets 2 and 4 before its first tag.

Read the rulesets back:

```sh
gh api repos/OWNER/REPO/rulesets --jq '.[] | {id, name, target, enforcement}'
```

Then read each ruleset by its `id`, with `gh api repos/OWNER/REPO/rulesets/<id>`, and compare its
`conditions`, `rules` and `bypass_actors` with the list above.

The branch protection of `main` keeps the App out of `main`, because the App is not an
administrator.

## Describe the components

1. Write `.changie.yaml` at the root of the repository, with `changesDir: .changes` and one
   project for each component. `EhosRelease.ChangieConfig` lists the keys that a release accepts.
2. Write `.github/ehos-release.json` with one entry for each component. `EhosRelease.Config` gives
   the fields, with an example.
3. Check that the two files agree. Each component names changie projects that exist, and its
   changelogs are the changelogs of those projects. A release refuses to open when they do not
   agree.

A change to a component then adds a fragment with `changie new --projects <project>`, in the pull
request that makes the change.

## Call the workflows

In eh-os and ehos_contract, pin both workflows by the commit that an `ehos_release-vX.Y.Z` tag of
ehos-tools names. A tag can move, and a commit cannot. Read the commit with:

```sh
gh api repos/EmpoweredHouse/ehos-tools/commits/refs/tags/ehos_release-vX.Y.Z --jq .sha
```

In ehos-tools, a caller names the two workflows by their local path, with no pin.

Each workflow asks for some permissions of the token of the job. The job of the caller must give
them, because a called workflow cannot get more than its caller gives. The examples below set
`permissions: {}` at the top of the calling workflow and give each job what it needs.

### Check the pins of each pull request

Call `ehos-pins.yml` from a job of the CI of the repository, on every pull request:

```yaml
pins:
  permissions:
    contents: read
  uses: EmpoweredHouse/ehos-tools/.github/workflows/ehos-pins.yml@<commit> # ehos_release-vX.Y.Z
```

It needs no secret. It fails when a pull request adds or moves a pin to a commit that is not on
the main branch of its repository.

### Release a component

One workflow of the repository, `release-pull-request.yml`, calls `ehos-release.yml`. It runs on
`workflow_dispatch` and on a push to `main`, and on no other event. It is the only workflow that
names the secrets `RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY`, and no workflow names the
environment `release-app`. In ehos-tools, `ehos-release.yml` itself names them too. Keep a test in the repository that holds these rules, as
`ReleaseWorkflowTest` in `packages/review` of ehos-tools does for `ehos-release.yml`.

The workflow calls `ehos-release.yml` three times, each time with an input `stage`:

| Stage | When | Inputs | Outputs |
| --- | --- | --- | --- |
| `open` | A maintainer starts the workflow on `main` | `component`, and `version` to release a higher version than the fragments give | none |
| `merged` | A push to `main` | `commit`, the pushed commit | `release`, `component`, `version`, `refused` |
| `tag` | After the costly checks of the repository, when `release` is `true` | `commit`, `component`, `version`, `refused`, and `checks`, the result of those checks | none |

Give each of the three calling jobs the same permissions: `contents: read`, `pull-requests: read`
and `issues: write`. GitHub checks the permissions of every job of `ehos-release.yml` when a call
starts, also the jobs of the other stages, which the call skips.

The calls of `open` and `tag` pass the two secrets by name. The called jobs read the values from
the environment `release-app`. Do not add the secrets to the repository or the organization: a
workflow on any branch can read those.

```yaml
on:
  workflow_dispatch:
    inputs:
      component:
        required: true
        type: string
      version:
        required: false
        type: string
  push:
    branches: [main]

permissions: {}

jobs:
  open:
    if: github.event_name == 'workflow_dispatch'
    permissions:
      contents: read
      pull-requests: read
      issues: write
    uses: EmpoweredHouse/ehos-tools/.github/workflows/ehos-release.yml@<commit> # ehos_release-vX.Y.Z
    with:
      stage: open
      component: ${{ inputs.component }}
      version: ${{ inputs.version }}
    secrets:
      RELEASE_APP_CLIENT_ID: ${{ secrets.RELEASE_APP_CLIENT_ID }}
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

Run the costly checks of the repository between `merged` and `tag`, on the merge commit. The
stage `tag` tags the commit only when `refused` is empty and `checks` is `success`. In all other
cases it opens an issue that says why.

## What can go wrong

- **The job `open, collect` fails with "A release opens from main".** You started the workflow
  on another branch. Start it on `main`.
- **The job `open, pull request` or `tag` fails before its first step.** The environment
  `release-app` does not let `main` deploy. Read the limit back with the commands in "Keep the
  key in the environment release-app". Add the branch policy for `main` again.
- **The token step fails.** One of the two secrets is missing or wrong, or the App is not installed
  on the repository.
- **The release refuses a pin.** No protected release tag names the pinned commit. Release the
  producer first, then move the pin to the commit that its tag names. If a tag names the commit,
  check ruleset 4 of "Protect the release branches and tags". It must include the prefix and
  exclude none of its tags.
- **GitHub refuses to start a called job.** The calling job does not give the permissions that
  "Release a component" names.
- **The stage `tag` opens an issue and makes no tag.** Read the reasons in the issue. Before you
  tag by hand, make sure that the tag does not exist already.

## Next steps

- [The README](../README.md): how a release goes, and what a pin is.
- `EhosRelease.Config`: the fields of `.github/ehos-release.json`.
