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
`.github/workflows/`. The release workflow refuses such a change before that.

## Keep the key in the environment release-app

The release workflow reads the key from the environment `release-app` of the repository. Do these
steps in this order. If a workflow names an environment that does not exist, GitHub creates it with
no limit on its branches. A workflow on any branch can read a secret that you add before the limit.

1. Create the environment, limited to branches that you name:

   ```sh
   gh api -X PUT repos/OWNER/REPO/environments/release-app \
     -F 'deployment_branch_policy[protected_branches]=false' \
     -F 'deployment_branch_policy[custom_branch_policies]=true'
   ```

2. Let `main` alone deploy to it:

   ```sh
   gh api -X POST repos/OWNER/REPO/environments/release-app/deployment-branch-policies \
     -f name=main -f type=branch
   ```

3. Read the limit back. No test sees this setting, so check it each time that you change the
   environment:

   ```sh
   gh api repos/OWNER/REPO/environments/release-app/deployment-branch-policies --jq '.branch_policies[] | {name, type}'
   ```

   The result is one line, `{"name":"main","type":"branch"}`.

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
   - **Bypass list**: the release App, and nobody else.
   - **Target branches**: the pattern `release/*`.
   - **Rules**: **Restrict creations** and **Restrict updates**. Leave deletions allowed, so that
     GitHub can delete a merged release branch.
2. Add the release App to the bypass list of the tag ruleset *Only admins create release tags*.
   Add it to no other ruleset.
3. Make sure that a tag ruleset refuses a tag named `main`. A tag with the name of a branch can
   confuse a job that reads the name of a ref.
4. Make sure that the tag ruleset *Release tags stay what they were* includes the tag prefix of
   each component. Make sure that its bypass list is empty. A release accepts a pin only to a tag that
   this ruleset protects.

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

Pin both workflows by the commit that an `ehos_release-vX.Y.Z` tag of ehos-tools names. A tag can
move, and a commit cannot. Read the commit with:

```sh
gh api repos/EmpoweredHouse/ehos-tools/commits/refs/tags/ehos_release-vX.Y.Z --jq .sha
```

ehos-tools calls its own copies by their path, with no pin.

### Check the pins of each pull request

Call `ehos-pins.yml` from a job of the CI of the repository, on every pull request:

```yaml
pins:
  uses: EmpoweredHouse/ehos-tools/.github/workflows/ehos-pins.yml@<commit> # ehos_release-vX.Y.Z
```

It needs no secret. It fails when a pull request adds or moves a pin to a commit that is not on
the main branch of its repository.

### Release a component

One workflow of the repository, `release-pull-request.yml`, calls `ehos-release.yml`. It is the
only workflow that passes the secrets `RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY`. It
calls the workflow three times, each time with an input `stage`:

| Stage | When | Inputs | Outputs |
| --- | --- | --- | --- |
| `open` | A maintainer starts the workflow on `main` | `component`, and `version` to release a higher version than the fragments give | none |
| `merged` | A push to `main` | `commit`, the pushed commit | `release`, `component`, `version`, `refused` |
| `tag` | After the costly checks of the repository, when `release` is `true` | `commit`, `component`, `version`, `refused`, and `checks`, the result of those checks | none |

Run the costly checks of the repository between `merged` and `tag`, on the merge commit. The
stage `tag` tags the commit only when `refused` is empty and `checks` is `success`. In all other
cases it opens an issue that says why.

## What can go wrong

- **The job `open, pull request` or `tag` waits, or fails before its first step.** The environment
  `release-app` does not let the branch deploy. Start the release from `main`. Read the limit back
  with the command in "Keep the key in the environment release-app".
- **The token step fails.** One of the two secrets is missing or wrong, or the App is not installed
  on the repository.
- **The release refuses a pin.** No protected release tag names the pinned commit. Release the
  producer first, then move the pin to the commit that its tag names.
- **The stage `tag` opens an issue and makes no tag.** Read the reasons in the issue. Before you
  tag by hand, make sure that the tag does not exist already.

## Next steps

- [The README](../README.md): how a release goes, and what a pin is.
- `EhosRelease.Config`: the fields of `.github/ehos-release.json`.
