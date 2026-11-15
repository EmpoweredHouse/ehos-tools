# Decision records

Why ehos-tools is the way it is, one decision per file, numbered `T-01`, `T-02`, … in the
[MADR](https://adr.github.io/madr/) format. Decisions about EHOS itself are EHOS's, numbered
`D-xx`, in [eh-os's `docs/adr/`](https://github.com/EmpoweredHouse/eh-os/tree/main/docs/adr), and
the choices made before these records began are in [`docs/research.md`](../research.md).

A record is written with the `ehos-dev:write-adr` skill, from the `ehos-dev` plugin ehos-tools
shares with eh-os, which holds the template and reads the section below for what is this
repository's. An accepted record is never rewritten: a later one supersedes it.

## Writing a record

- **Prefix and number.** `T-xx`, as [T-01](0001-ehos-tools-keeps-its-own-decision-records.md) set
  up: `0003-…` is `T-03`, the next number after the highest in this directory. Open questions and
  guesses are not records: they stay in [`docs/spike.md`](../spike.md), "Open".
- **Whose decision.** A decision about how ehos-tools is built, released or behaves toward a
  developer is a `T-xx`. A decision about what EHOS requires of an application, or that EHOS's own
  components rely on (the design system's place, eh-os D-72; sign-in, D-64), is a `D-xx`, written
  in eh-os. Here it is cited as `eh-os D-xx`, linked by its GitHub URL. When both apply, EHOS's
  record decides and the `T-xx` records only what ehos-tools does about it.
- **Where to search first.** This directory, [`docs/research.md`](../research.md) ("Decisions and
  why", the choices made before these records began) and EHOS's decisions. A choice in
  `docs/research.md` that is revisited gets a `T-xx` that supersedes it, and `docs/research.md`
  points to that record.
- **What constrains a decision.** `CONTRIBUTING.md`, `AGENTS.md`, [`docs/spike.md`](../spike.md)
  ("Open"), and EHOS's specification
  ([ARCHITECTURE.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ARCHITECTURE.md),
  [ROADMAP.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ROADMAP.md)). A decision that
  goes against one of them says so and explains why it should change, and the same pull request
  changes it, or files the change in eh-os. The context links what makes the decision necessary: an
  earlier `T-xx`, an EHOS decision (`eh-os D-xx`), an issue, a section of `docs/spike.md`. Earlier
  findings are cited by where they are (`docs/spike.md`, a commit, an issue).
- **What a Confirmation cites.** The test, check or CI job that would fail
  (`Ehosctl.TemplateTest`, the installer's idempotency test, the `e2e` job).
- **How to link.** Within the repository by relative path (`../spike.md#…`,
  `../../CONTRIBUTING.md`); another repository by its GitHub URL, never a local path.
- **What follows a new record.** A row in "The records" below, and every relative link in the record
  checked.

## The records

| ID | Decision | Status |
| --- | --- | --- |
| [T-01](0001-ehos-tools-keeps-its-own-decision-records.md) | ehos-tools keeps its own decision records, numbered T-xx, beside EHOS's D-xx | accepted |
| [T-02](0002-a-project-takes-a-later-ehos-app-by-running-the-installer-again.md) | A project takes a later ehos_app by running its installer again, not through `mix igniter.upgrade` | accepted |
| [T-03](0003-ci-checks-that-a-pull-request-records-its-authors-review.md) | CI checks that a pull request's description records its author's review | accepted |
| [T-04](0004-ci-runs-only-what-a-change-or-a-release-needs.md) | CI tries the binaries end to end only for a release, and checks and builds only what a change touches | accepted |
| [T-05](0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md) | A generated project follows eh-os-contract's `main` while eh-os-contract tags no release | superseded by T-11 |
| [T-06](0006-ehosctl-reads-its-command-line-with-optimus-and-writes-to-the-terminal-with-owl.md) | `ehosctl` reads its command line with Optimus and writes to the terminal with Owl | accepted |
| [T-07](0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md) | `ehosctl` keeps installations as named contexts, one current, in a JSON file in `~/.config/ehosctl` | accepted |
| [T-08](0008-ehosctl-keeps-a-sign-in-s-refresh-token-in-the-system-s-keychain-else-a-file-only-the-user-reads-and-renews-under-a-lock.md) | `ehosctl` keeps a sign-in's refresh token in the system's keychain, else in a file only the user reads, and renews it under a lock | accepted |
| [T-09](0009-ehosctl-signs-in-with-oidcc-and-answers-the-browser-on-a-loopback-socket-of-its-own.md) | `ehosctl` signs in with oidcc, and answers the browser on a loopback socket of its own | accepted |
| [T-10](0010-ehosctl-call-reaches-an-application-through-eh-os-contract-s-routes-found-through-ehos-s-api.md) | `ehosctl call` reaches an application through `eh_os_contract`'s routes, found through EHOS's API | superseded by T-12 |
| [T-11](0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md) | A generated project pins eh-os-contract's release by the commit its tag names, and moves to a later one with a release of `ehos_app`; supersedes T-05 | accepted |
| [T-12](0012-ehosctl-call-asks-for-a-capability-no-role-grants-so-its-refusal-is-decided-and-recorded.md) | `ehosctl call` asks for a capability no role grants, as each kind in turn, so its refusal is decided and recorded by EHOS or the application; supersedes T-10 | accepted |
| [T-13](0013-ehosctl-runs-the-platform-plane-s-tools-pinned-through-mise-and-keeps-an-installation-s-server-under-the-name-its-governed-commands-use.md) | `ehosctl` runs the platform plane's tools pinned through mise, and keeps an installation's server under the name its governed commands use | accepted |
| [T-14](0014-ehosctl-login-keeps-the-ca-it-was-told-to-trust-beside-the-installation-and-trusts-it-for-that-installation-alone.md) | `ehosctl login` keeps the CA it was told to trust beside the installation, in `config.json`, and trusts it for that installation's commands alone | accepted |
| [T-15](0015-an-application-s-skills-are-the-ehos-app-plugin-its-claude-code-settings-enable-not-copies-in-the-project.md) | An application's skills are the `ehos-app` plugin its Claude Code settings enable, not copies in the project | superseded by T-28 |
| [T-16](0016-applications-take-the-ehos-app-plugin-from-a-marketplace-of-its-own-name.md) | Applications take the `ehos-app` plugin from a marketplace of its own name, `ehos-app`, which ehos-tools publishes beside `ehos-tools`; amends T-15's marketplace | accepted |
| [T-17](0017-an-application-s-review-gate-is-ehos-app-s-tasks-a-hook-its-installer-writes-and-a-skill-an-assistant-runs.md) | An application's review gate is `ehos_app`'s: `mix ehos_app.review`, a hook and a `review` workflow its installer writes, and `/ehos-app:pre-pr-review`, which an assistant can run | accepted |
| [T-18](0018-in-a-github-actions-job-ehosctl-talks-to-the-installation-ehosctl-url-names-and-exchanges-the-job-s-token-for-each-credential-keeping-nothing.md) | In a GitHub Actions job, `ehosctl` talks to the installation `EHOSCTL_URL` names and exchanges the job's token for each credential, keeping nothing | accepted |
| [T-19](0019-ehosctl-builds-register-states-what-a-github-actions-job-s-checkout-and-event-say-of-its-commit-and-elsewhere-nothing.md) | `ehosctl builds register` states what a GitHub Actions job's checkout and event say of its commit, and elsewhere nothing | accepted |
| [T-20](0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md) | Code in ehos-tools and in the applications it generates is behaviour-driven: a collaborator a test replaces is a behaviour with its implementation beside it, mocked with Hammox; an application or `ehosctl` chooses it in configuration, a library in `opts` | accepted |
| [T-21](0021-eh-os-s-diagram-generator-is-shared-as-ehos-diagrams-a-package-here-that-takes-its-vocabulary-and-ehos-design-from-its-host.md) | eh-os's diagram generator is shared as `ehos_diagrams`, a package here that takes its vocabulary and `ehos_design` from its host, which pins it by commit in `:dev` and `:test` | accepted |
| [T-22](0022-a-session-is-told-and-a-pull-request-refused-when-the-machine-holds-an-older-tag-of-a-pinned-marketplace.md) | A session is told, and a pull request refused, when the machine holds an older tag of a marketplace the repository pins; a later tag passes, with a note | accepted |
| [T-23](0023-the-reviews-before-a-pull-request-use-ehos-tools-own-method-not-the-harness-s-review-skills.md) | The reviews before a pull request use ehos-tools' own method, in the plugins, not the harness's review skills; amends T-17's correctness review | accepted |
| [T-24](0024-acme-dns-s-image-is-kept-current-by-renovate-run-in-a-workflow-of-ehos-tools-under-a-github-app-of-its-own.md) | acme-dns's image is kept current by Renovate, run weekly by a workflow of ehos-tools under a GitHub App of its own, and a weekly scan of the pinned digest opens an issue | accepted |
| [T-25](0025-acme-dns-takes-port-53-of-the-node-s-own-addresses-through-a-service-s-external-ips-not-servicelb-s-host-port.md) | acme-dns takes port 53 of the nodes' own addresses through its Service's external IPs, not through ServiceLB's host port, which also took the node's resolver stub | accepted |
| [T-26](0026-a-new-application-starts-its-development-postgresql-with-docker-compose-on-port-5435-which-pgport-overrides.md) | A new application starts its development PostgreSQL with Docker Compose, on port 5435, which `PGPORT` overrides; CI sets `PGPORT` to its own | accepted |
| [T-27](0027-a-utility-service-s-pipeline-is-a-workflow-of-ehos-tools-released-by-ehosctl-s-tag-which-installs-the-ehosctl-of-that-tag.md) | A utility service's pipeline is a workflow of ehos-tools, released by `ehosctl`'s tag `vX.Y.Z`, which installs the `ehosctl` of that tag, checked against that release's `SHA256SUMS` | accepted |
| [T-28](0028-applications-get-versioned-filesystem-skills-beside-claude-plugins.md) | Applications get versioned filesystem skills beside Claude plugins; supersedes T-15 | accepted |
