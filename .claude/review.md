# Reviewing a change to ehos-tools

This repository's half of the `ehos-dev:pre-pr-review` skill: the skill holds the procedure and
reads this file first. `CONTRIBUTING.md`, "Commits and pull requests", has the same rules for a
person.

## Recording the review

`cd packages/review && mix review record` marks `HEAD` as reviewed. It refuses while changes are
uncommitted. The mark is a file in the repository's common git directory, so every worktree sees
it; it is never committed.

A Claude Code hook (`.claude/settings.json`) runs `mix review gate` in `packages/review` before the
command that opens a pull request (`gh pr create` or `gh pr new`), from the checkout it runs in, and
refuses it while that checkout's `HEAD` has no mark. It also refuses one that names another branch
or repository (`--head`, `--repo`), or that commits, checks out or rebases before it opens the pull
request: commit, record, then open it on its own. While `HEAD` is unreviewed it refuses any other
Bash command that names the one that opens a pull request, a `grep` included, and, whatever `HEAD`
is, a `git commit` whose message names it; write such text through a file (`git commit -F <file>`).
It does not see a push to an open pull request, or one opened through the API.

`mix review record` and the gate also refuse while this machine holds an older tag of a
marketplace than `.claude/settings.json` pins, or only an older version of its plugin
(`mix review plugins`, T-22): the reviews ran with older skills than the ones this
repository asks for. A later tag passes. A `SessionStart` hook runs the same check at the start of
each session and prints the commands that move the machine.

## Documentation alone

Markdown that no code reads and that sets no rule a review or an agent follows: `README.md`,
and `docs/` except `docs/adr/README.md`.

Everything else is reviewed, though some of it starts no package's `check` job in CI. That is
anything not Markdown (`.claude/settings.json` and its hook, `.tool-versions`, `.gitattributes`,
every file under `.github/workflows/`, `release-package.yml` included); everything under
`packages/`, whose READMEs, changelogs, templates and `SOURCE.md` its code, its workflows or ExDoc
read; everything under `plugins/` and `.claude-plugin/`, since the `ehos-dev` plugin is what eh-os,
ehos-tools and ehos_contract run; and what sets the rules a review checks against: `AGENTS.md`,
`CONTRIBUTING.md`, `.claude/skills/`, `docs/adr/README.md` (its "Writing a record") and this
file.

## Security and performance

Secrets and tokens (in CI, in a Dockerfile, in what a generated project commits), trust in fetched
code and pins (a tag can move, a commit cannot), what a generated application serves and which
cookies, authentication and sign-in, unbounded work, work repeated on every run of the installer.

## The checks

`mix check` in every package the change touches. Run `ehos_app`'s from a checkout whose path has no
dot directory (`AGENTS.md`, "Traps already found").

## Verifying for real

A change to `ehos_app` generates a project and runs its `mix precommit`; a change to `ehosctl`
builds the binary and runs `init` with it (`AGENTS.md`, "Trying a change end to end").

## A finding skipped

A GitHub issue labelled `follow-up`, naming the pull request that found it. The
`ehos-dev:triage-follow-ups` skill works through the open ones.

## The pull request

The `ehos-dev:pull-request` skill writes the description and opens the pull request. This section
gives the rules that are this repository's own. `.claude/settings.json` pins a tag of `ehos-dev`
that has the skill, and `ehos-core` comes from the same tag. If the session does not have it, its
plugin did not load or Claude Code still holds an older version: tell the user, who restarts
Claude Code. In a run with no user, stop and report it, as `AGENTS.md` says for a skill the session does not know. A machine that
added the marketplace at an earlier tag moves to the pinned one as `CONTRIBUTING.md`, "Releasing
the `ehos-dev` plugin", says.

- **The base** is `main`, and the pull request is not a draft.
- **The title** is a short sentence that says what changes for a reader, as a commit subject is
  (`CONTRIBUTING.md`, "Commits and pull requests").
- **The first line** names the issue and, for a step's part, the eh-os step: "Closes #110. Part of
  EmpoweredHouse/eh-os#371 (Stage 7, step 14)." (`CONTRIBUTING.md`, "From an issue to `main`").
- **A changelog line.** A change a user of `ehosctl`, `ehos_app`, `ehos_design`, `ehos_diagrams`,
  `ehos_platform`, `ehos_tunnel` or `ehos_release` can see has its line under `## [Unreleased]`. Otherwise the description has a
  line `No changelog: <why>`, at the end of "What", which CI's `changelog` check reads.
- **A change to a procedure of `ehos-core`** says in "How it was tested" that no benchmark exists
  yet, until the benchmark T-33 describes is merged: the line `No benchmark exists yet.` The same
  holds for a change to this repository's part of `plan` or `retro`: a move of the `ref` in
  `.claude/settings.json`, or a change to `CONTRIBUTING.md`, "Where the work is recorded" or
  "From an issue to `main`". Until the benchmark holds cases for `retro` and `plan`, the two
  reviews and the user alone judge a change to either, or to this repository's part of them. The
  same line says so. Once the benchmark merges, this rule becomes its result and cost, which CI's
  `review section` check then reads.
- **No sections of its own** beyond the template's.

CI's `review section` check fails while `## Review` is missing or empty, and runs again when the
description is edited.

## Before a fix

Nothing beyond the procedure.

## What reviews of this repository keep finding

Look for these on purpose; each one has already happened here.

**The installer (`packages/ehos_app`)**

- A second run changes nothing. A file the developer owns is written once (`write_rendered/3`,
  never `Igniter.create_new_file/4` with `on_exists: :skip`, which overwrites a file Igniter has
  not read yet), and what the developer removed or declined is never brought back: a declined
  design system, a moved sign-in link, a tuned daisyUI theme.
- A change to `ci.yml.eex` adds the SHA-256 of the workflow it replaces to
  `@earlier_ci_workflows`, and that file to `test/fixtures/ci_workflows/`: a workflow an earlier
  version wrote, untouched, is replaced only when the installer knows its bytes.
- A project from an earlier version is a separate case from a new one, with its own test: what it
  already has (a migration that went to an earlier version, a workflow from 0.2, a package on a
  commit no version pinned) decides what the run adds. Test the project moved by hand before the
  run as well as the one left as it was.
- Code is read as code. A regular expression over source matched a call in a comment and missed
  one split over lines; parse it (`Code.string_to_quoted/2`) instead, and say what a file that
  does not parse means.
- Supervision order is what Igniter makes of it, not what the call suggests: it inserts after the
  child that follows the last `after:` match. Check the generated `application.ex`, and that the
  endpoint starts last.
- A literal the project wrote that defeats the change (`secure: false`) is replaced; an expression
  of its own stays.
- A notice says what the developer has to do, in words that match what the run did.
- What the installer writes from a newer release of a dependency (a module, a child, a route) is
  written only where the project is on that release: one kept on a commit of its own may not have
  it, and a child or a forward naming a module it lacks fails the boot (`contract_pins/1`, #882).

**The platform's installer (`packages/ehos_platform`)**

- A step before the prerequisites runs on a new server too, where cert-manager, CloudNativePG and
  Traefik are not installed: a `kubectl get` of one of their kinds there exits 1 with "the server
  doesn't have a resource type", which `--ignore-not-found` does not cover. Ask for the kind's CRD
  first, an object the API server answers for, as `bundled_traefik` does: kubectl's "no resource
  type" says the same of a running installation whose kind is not served yet after a restart. The tests answer every call with exit 0 unless told; test the new server's answer
  (eh-os#1236).
- kubectl's `-o json` is indented over many lines: never parse it line by line, as helm's one-line
  JSON is (`last_json/1`). A Secret that was there was never read, so a run again was refused. Read
  it as `kubectl_json/2` does, and answer with `Jason.encode!(value, pretty: true)` in its test
  (ehos-tools#992).
- A value that can be large, such as a CA's PEM, never goes into one argument: Linux takes at most
  128 KiB in one, and an RDS bundle is about 160 KB. Give it to Helm in a values file only this user
  reads, as `with_private_json/3` writes one (ehos-tools#992).

**The server's administrators (`EhosPlatform.Server.Administrators`, eh-os D-199)**

- A filter that hides what the system made, in a list meant to show what a person planted, hides
  exact pairs only: a prefix such as `system:` or `helm-kube-system-` let anyone with
  `cluster-admin` name a binding so that `admin list` left it out.
- A file read back from the server inside a framed answer comes in base64, with its hash checked
  on the workstation: a line of the file equal to the frame's marker broke every command.
- A record copied from another workstation (`installation.json` in a handover) names another
  person: check it against the server before acting as them, as `tunnel` does.
- A key already on the server without a name can be the key every administrator shares: never
  give it a person's name.
- A mark in `installation.json` travels with every copy of the folder, a handover's included: a
  mark that lets a command act without being told (`administrator_pending`, which lets `up` name
  a person by default) says whose it is, and is honoured only for them.
- A command run on the server over SSH has its own time limit (`kubectl --request-timeout`): SSH's
  keepalive holds a session open while the remote command waits for ever.
- A new result of a step that several paths share reaches every caller: `execute/3` gained
  `:changed`, and `up`'s first administrator, which called it directly, returned the bare atom,
  on which ehosctl crashed (eh-os#1836). Find each caller of a function whose results change.
- GCP's guest agent writes `authorized_keys` without a lock, from what it read before: a login
  that works after a write does not show the write is still there. Check the file's hash.
- What `up` recorded (the place in `installation.json`) does not say a server is there: it is
  written before the apply, and kept by an apply that failed and by `down`. Read the plan.
- A check that a removed key is gone looks for the key's blob in the text of every line, of every
  kind: the agent's line, a copy that names nobody, and a line ehosctl's parser does not read (a
  CRLF ending), which sshd may. A check of the named line alone reported a person removed while
  the agent had written their key back (ehos-tools#1155, #1157). GCP's metadata is checked the
  same way, by text, and its flags as the agent reads them (`strconv.ParseBool`, no trim).
- A record ehosctl leaves on the server for a run again (`# ehos-administrator-removed:`) is read
  narrowly, since anyone who writes the file can forge one: a whole key only, as a short blob
  matched inside every other key. Every command that reads the file decides what the record means
  to it (`add` of the same name, `admin list`, the check on exit 77), and a run again that the
  message offers must be one that can finish (#1157).
- GCP's guest agent writes a key in the metadata for any user into that user's own
  `authorized_keys`, and makes the user a sudoer: a check of ubuntu's file alone is not a check of
  the server (#1157).
- A script on the server whose failure ehosctl prints keeps what it read until it has read it
  all: the metadata script printed the keys it had read, with comments that are people's email
  addresses, when a later request failed. And a failure inside `$(…)` is caught (`v=$(…) ||
  exit`), or it reads as an empty value (#1157).
- sh has no pipefail: `kc … | grep | cut` reads a kubectl that failed as nothing there, and a
  rotation of the client CA finished with EHOS at zero and its counts removed. Capture what a
  command printed, with its own status, before any pipeline that reads it (eh-os#1836).
- A check of a program's output on the server is tested against what that program prints, read in
  its source, never against what a stub guessed: k3s's `token rotate` always warns, and a check for
  "warn" undid every rotation on a real server while the tests passed (eh-os#1836).
- A secret in a script on the server never reaches the arguments of a program, `grep` included:
  any user on the host reads `/proc/<pid>/cmdline`. Match it with the shell's own `case`, and give
  it to the program that needs it in its environment (eh-os#1836).
- `systemctl start` or `restart` of a unit with `TimeoutStartSec=0`, as k3s's is, waits for ever on
  a service that never gets ready: bound it (`timeout`), or the undo after it never runs
  (eh-os#1836).
- A process that may be undone and run again records on the disk the point after which it is never
  undone, and checks it before anything puts a copy back: a run again that cannot reach the API
  cannot read an annotation (eh-os#1836).

**`ehosctl`'s governed commands**

- A read that follows a decision needs its own capability, which the person who decided may not
  hold: a process owner approves a promotion with `ehos.release.approve` alone, and may not read
  production's deployments. Such a refusal after the decision is not the decision's (#246).
- An id EHOS answers is in lower case whatever case it was asked in (`Ecto.UUID`): compare what it
  answers with an id sent in lower case, not with the one the person typed (#246).
- A fake answer of EHOS in a test is EHOS's own: its status, its code and its sentence, read in
  eh-os's controller and `docs/*-api.md`. A refusal code EHOS never sends (`no_application` for
  its `not_found`) made a test pass while a real EHOS failed the command (#917).
- A check added to a helper that two paths share reaches both: a refusal of a link at `_build`,
  meant for a utility service's repository, refused every application whose `_build` is a link
  (#917). Test the other path when a shared helper changes.
- An error's message is a string or an `Ehosctl.Failure`. Code that uses it as a binary (`<>`, a
  `String` function, `is_binary/1`) fails on a Failure; use `Failure.added/2`, `Failure.said/1`
  or `Failure.sentence/1`. A fake that answers a string where `Ehosctl.HTTPImpl` gives a Failure
  hid a crash that printed no error at all (#979).
- In `ehos_platform`, an error of a failed `tofu`, `helm`, `kubectl` or `ssh` is an
  `EhosPlatform.Failure`, not a string. A clause `{:error, message} when is_binary(message)` before
  a catch-all drops it without a word: `Server.pin/1` let `up` succeed with the account not
  recorded (#979). Match the Failure too, and give the test a fake that answers one.
- A command under `Next:` or `What to do:` is pasted into a shell. Each value in it that ehosctl
  did not write itself, a name EHOS echoes above all, is quoted with `EhosPlatform.Shell.word/1`;
  `Refusal.shown/1` escapes for the terminal, not for a shell: `apps register` would have given
  `ledger; curl … | sh` to run (#979). A word to replace is in capitals, never `<word>`.
- A governed command's offered command names its installation through `Config.command/2`, never
  `--installation #{name}` by hand: in a GitHub Actions job the name is `EHOSCTL_URL`, which no
  kept installation has, and the pasted command failed (#1148).
- A command offered to read a secret in the person's shell keeps it out of every environment:
  in a subshell, after `unset v; set +a`, since an exported `v` or `allexport` sent the value
  into ehosctl's environment and every program it starts (#315).
- Advice that ends in a colon goes with its commands when none can be printed: advice a person
  needs without the command ends in a full stop (`Failure.pasted/2`).
- A value from EHOS with a control character makes `Output.render` print the whole line in
  double quotes, where a shell expands the `$(…)` that `Shell.word` kept in single quotes. A
  command is printed only through `Output.next/1` or `what_to_do/2`, which leave such a command
  out, with the advice ending in a colon that introduced it (`Failure.pasted/2`). A sentence that
  offers a command, a `look:` among them, quotes its values with `Shell.word`, never
  `Refusal.shown`, whose `inspect` double quotes let a shell expand `$(…)`, and goes through
  `Output.offered/2`, which leaves it out when a value is not `Output.printable?/1`, since
  `render` doubles the `\` of `'\''` (#979, #1047). The sentence gives each command as
  `{:command, command}`, apart from the words, never between backquotes of its own: a backquote
  in a value shown in the words would move where the command starts (#1081). A `look:` is the
  bare command.
- Every offered command passes `Output.pastable?/1` (`EhosPlatform.Shell.pastable?/1`), which
  reads its words as a POSIX shell does: a value that holds `\` is left out, since fish reads it
  inside single quotes, and so is a quoted value that starts with `-`, which the command reads as
  an option; `Shell.word/1` quotes every value that starts with `-`. So an unquoted word that
  starts with `-` is the command's own option: never write a value into a command but through
  `Shell.word/1`, and never quote an option of the command. A command printed as a program ran it
  (`init`'s steps) writes its own options unquoted (#1062, #1063).
- A value from EHOS in an address (the console's page of a domain) is a segment built with
  `Api.segment/1`, never `Refusal.shown/1`, whose quotes are for a terminal (#1061).
- A command whose words leave out a command that `Output.pastable?/1` refuses gives the same
  commands under `--json`: filter them once, where the result is built, and keep the sentence
  that introduced them (#1105).
- A printed `ehosctl server up` keeps what the server has: each `up` replaces the blocks
  `--ssh-from` admits with the ones it is given, and a new SSH key makes the server again on
  AWS, Oracle and OVHcloud. A procedure that prints one gives the recorded blocks and the shared
  key (#1105).
- Advice to run the command again holds only for a command that has changed nothing yet: a read
  that follows a write (a deployment's history after EHOS decided it) does not get it (#979).
- A date a person reads goes through `Output.date/1`, which also takes `nil` and text that is not
  ISO 8601, and a value that is not there is `Output.none/0` (`<none>`), never `none`, `-`, an
  empty cell or words in brackets: a seed profile can be named `none`. A value that is there but
  not known, or that has a meaning (`never`, `n/a`), says so in words. `Ehosctl.ValuesTest` and
  `Ehosctl.Case.ehosctl/2` fail on a raw date, `(none)` and `(not set)`, but not on `none`, `-`
  or an empty cell, nor on a question asked through `Ehosctl.Terminal`: look for those (#979).

**Pins and releases**

- A dependency from GitHub is pinned to a commit, with the tag it carries in a comment: a tag can
  move. ehos_contract too: a generated project pins its release by the commit its tag names, and
  moves to a later one with a release of `ehos_app` ([T-11], which superseded T-05's
  `branch: "main"`). The toolchain, archives and installer version are pinned in
  `packages/ehosctl/lib/ehosctl/template.ex` alone.
- A change to what the installer writes reaches a project only through an `ehos_app` release; a
  release of `ehos_app` is a release of `ehosctl` once `template.ex` points at it. Unreleased fixes
  do not reach anyone who installs a binary.
- No version changes outside a release's pull request, or the one after its tag that moves to the
  next `-dev` (`ehos-dev:release`).
- Every repository a generated project reads that is private (`ehos_contract`, this one) is
  readable in its CI workflow and through its Dockerfile's build secret.
- A CI check of what a pull request changes reads its merge commit, the checkout's `HEAD`
  against `HEAD^1`, not `base.sha` against `head.sha`: a branch cut before a release still holds
  the `[Unreleased]` line that merging carries into the release's section (#585).
- A patch release sets a version below the `-dev` it replaces (`0.13.0-dev` to `0.12.1`): code
  that tells a release by its version compares it with the versions released, not with the
  `-dev` (#585).

**Docs and messages**

- Documentation says what the code does. A commit message that claims a fix the code makes only
  in part costs the next round; the review compares the two.
- A change a user of `ehosctl`, `ehos_app`, `ehos_design`, `ehos_diagrams`, `ehos_platform`, `ehos_tunnel` or `ehos_release` can see has its changelog line under
  `## [Unreleased]`, in one of the six standard subsections, describing the change for a reader of
  the package and wrapped at 100 columns; or the description has `No changelog: <why>`. A
  breaking change's line starts with `**Breaking:**`, and a link in it is a GitHub URL, since the
  section becomes the release's notes.
- A change that edits an `[Unreleased]` line stays there only while its package is unreleased.
  A release cut while the pull request is open moves the line under its version, and a clean
  rebase, or the merge button, carries the edit there, into notes the release never had (#576).
  CI's `changelog` check fails such a pull request when the release is on `main` as it runs, and
  `main` after the merge when it was not (#585). Before merging a pull request whose package was
  released since the check last ran, merge `main` into it, so the check runs on the release.
- No local paths, and links to other repositories by their GitHub URL.
- A rule removed because its first reason is gone can still guard something else: the steps for
  running a fork's change here existed for the CI App's key, and also kept a fork's code from a
  run whose `github.token` can write releases (#1169). Before removing a rule, list what else it
  stops.
- A skill's rule is one its subagent can follow and the agent that runs it can check. "Only read"
  told to a subagent that holds `gh` and the user's token is neither: the parent never sees its
  calls, and `gh api` posts once given `-f`. Fetch what the subagent needs into files, and name
  the tools it uses, the ones its own steps call for included (#1176).

**Elixir and tooling**

- A review command offered to another harness checks that harness's installed skills. Test a
  machine that also has Claude installed with missing or stale plugins: its cache must not block
  a valid Codex marketplace-plugin review (#931).
- A new collaborator a test replaces is a behaviour with its implementation beside it and a
  Hammox mock ([T-20]). In new code, a function in `opts` for one, a test that swaps an
  implementation through `Application.put_env` or `System.put_env`, or a module that is not a
  behaviour's implementation running a program, calling HTTP or reading the environment
  (`System.cmd`, `Port.open`, `Req`, `:httpc`, `System.get_env`, `System.fetch_env`), or reading
  the clock or randomness where a test must say what they return, is a finding. Not a finding:
  `mix.exs`, `config/*.exs` and a Mix task reading the environment, and the code the installer
  writes into a project. Code written before the rule is not either, even where a change touches
  it, until its area moves.
- A `@callback` without a `@doc` is a finding, in a package (`ehos-dev:elixir`, rule 6) and in what
  the template writes, where the generated `test/callback_docs_test.exs` holds it.
- A `use` an installer adds goes after the module's own `use`s: Igniter finds a repo by the first
  `use` in its module (`select_repo/2`), so a `use Boundary` above `use Ecto.Repo` made a second
  run find none (ehos-tools#506). A test case, which nothing finds by its `use`, may take one
  first, as `ConnCase`'s Boundary does, before the setup the run put after its own.
- A docs test that checks `doc != :none` passes a function component without a `@doc`:
  Phoenix.Component writes one from its attributes and slots. Count that one as none.
- A process started with `start_link` from another's callback has that process as its parent:
  when the parent exits, `gen_server` calls `terminate/2` and never `handle_info/2`, even when the
  child traps exits. A goodbye written in `handle_info({:EXIT, …})` never runs (#935).
- A process that holds a credential (a private key in `:ssl` options, a token) redacts it in
  `format_status/1`: a crash report prints the state and the last message (#935).
- Mint gives the bytes that came in the same read as a `101` as that answer's body, before
  `:done`: they are the first WebSocket frames, not a body to drop (#935).
- A test of a split, a limit or a timeout is checked against what the transport really does: a
  loopback read is about 9 KB, so a test that writes 3 MiB never sees a read split into frames
  (#935).
- A test of mailed HTML that parses it before looking for links, images or scripts misses what
  sits in Outlook's conditional comments, which a parser reads as comments and Outlook renders.
  What the HTML fetches or links to is read in the HTML as written.
- `Regex.replace/3` with a string replacement reads `\1` followed by digits as a larger group
  number: when the inserted text can start with a digit, replace with a function.
- A test helper that keeps the caller's git out of the tests by clearing what
  `git rev-parse --local-env-vars` names clears `GIT_CONFIG_COUNT` too, the variable through
  which CI hands a test that reads a private repository its token, and turns off the developer's
  credential helper with the global configuration. The helper isolates every run, since a test
  picked by `file:line` replaces `--only`'s filter after it has loaded, and those tests give the
  caller's values back to their own git alone (ehos-tools#506,
  `packages/ehos_app/test/test_helper.exs`).
- A test rewritten to compare whole lines keeps every absence the old one refuted: comparing the
  one line the installer changes misses what it adds beside it.
- A test that runs a clock faster than the real one, to shorten a socket's timeout, shortens every
  wait read from that clock: a limit the test asserts on real time must still be able to fail
  within the wait, or the test checks nothing and flakes on a slow runner (ehos-tools#571).
- A test that reads compiled code (`:beam_lib`, `debug_info`) or picks modules by their source
  path works under `mix test --cover`, where `:code.which/1` names no file, and from a checkout
  anywhere, a path under a `lib/` directory included, and fails, rather than checking nothing,
  when no module matches (ehos-tools#571).
- A library call that reads as building something can send a request: oidcc's
  `create_redirect_url` posts a pushed authorization request when discovery names an endpoint for
  it. Read the library's source for what a call sends before a module that is not a behaviour's
  implementation calls it, and give it the request options every other request gets (#696).
- A test server that keeps connections alive hides a request made without its TLS options:
  `:httpc` sends it over a connection an earlier request opened and verified. A fake that checks
  trust closes each connection after its answer (`Ehosctl.FakeIssuer`, #696).
- A `receive` whose `after` waits for a program to end starts again with each message, so output
  that keeps coming never reaches it: count the wait from a deadline. On it, kill the program by
  its OS pid, since a release's `stop` needs distribution, which a generated project turns off
  (#882).
- A value a `with` clause binds is not in scope in its `else`: a cleanup there sees the state
  from before that clause, and a listener bound in the `with` stayed open (#924).
- What a command opens at EHOS, such as a data session, is ended on every way out: each answer
  the command refuses, an exception (`try … after`), and an answer of a shape it cannot read,
  where a `FunctionClauseError` from a parse skipped the end (#924).
- A program a person uses on the terminal (psql) runs through `Ehosctl.Runner.foreground/3`:
  under Burrito `ehosctl`'s stdout is a pipe, where psql shows no prompt, and Ctrl-C reaches the
  launcher and the VM, which stops in its break menu (#924).
- A program a port starts has no controlling terminal: OTP's `erl_child_setup` calls `setsid()`
  for each one, so `/dev/tty` fails there, and a terminal cannot be made its own. A check of a
  shell line at a terminal, or a test with the runner mocked, does not see it; run it through
  `Port.open` in a VM at a pseudo-terminal (`Ehosctl.RunnerTest`, #976).
- util-linux's `script -c` runs its line in `$SHELL`, whose own files (config.fish, .zshenv) run
  first and can set what the program reads: give it `SHELL=/bin/sh` (#976).
- A test that writes to the filesystem does it under its own `tmp_dir`; a test of the installer
  runs on `Igniter.Test.phx_test_project/1`, and a CLI test reads the steps a command would run.
- An option threaded through a command's `opts` (`:env`, `:ca`) reaches every request only if no
  call site rebuilds the list: a `Keyword.take(opts, [:env])` before one request dropped the
  installation's CA there (#148). Follow each new option to every request it must reach.
- What ehosctl prints of an error must not hold a value: a `KeyError` over `opts`, a
  `MatchError`, an `ErlangError` or an `ArgumentError` carries the term, which can be the
  environment or a credential, and stderr is a CI job's log. `Ehosctl.Application.run/2` prints
  only messages known to hold none, and traps exits so that a crashed task reaches it; an
  exception ehosctl defines that holds none is added there, and the environment and credentials
  stay out of `opts` all the same.
- A cleanup that removes what ehosctl left on a person's machine (a temporary directory, a
  partial write) matches its own files by a shape no person's file has, and also the shape a
  released version gave them: `ehos.*-<16 characters>` matched a person's own
  `ehos-tools-review-pr-1106-backup`, and the narrower shape that replaced it no longer matched a
  released version's leftovers, the only ones there were (#1108).
- Burrito binaries reuse an unpacked payload for their version: an end-to-end check after a
  rebuild at the same `-dev` version runs `maintenance uninstall` first, or it tests the old code.
- A page that tells a maintainer how to set up GitHub (an environment, a ruleset, a caller of a
  reusable workflow) is read against what the workflows and the checks read, and against the live
  settings with read-only `gh api` calls. A setting the page names may not exist yet; a ruleset
  is read as the check reads it (active, the exact pattern, excludes, bypass); and a caller gives
  the permissions of every job of the called workflow, since GitHub checks them all when the call
  starts, the skipped ones too.

[T-11]: ../docs/adr/0011-a-generated-project-pins-eh-os-contract-s-release-by-the-commit-its-tag-names.md
[T-20]: ../docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md
