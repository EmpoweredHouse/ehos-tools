# review

The review gate of ehos-tools. Every change to this repository is reviewed by its author before
its pull request is opened, and this package holds them to it: it records that a commit was
reviewed, refuses to open a pull request from one that was not, and checks in CI that the pull
request says what the review found
([T-03](../../docs/adr/0003-ci-checks-that-a-pull-request-records-its-authors-review.md)). It
also holds CI's check that a pull request leaves released changelog sections as they were
("The changelog check", below), and its check that a change to a plugin raises the plugin's
version ("The plugins' check", below).

It is a tool for working on this repository, never released and never depended on. The gate
itself is `EhosApp.Review`, in [`packages/ehos_app`](../ehos_app), the one every application
`ehos_app` generates has: this package depends on it by path and gives it ehos-tools' marks and
messages
([T-17](../../docs/adr/0017-an-application-s-review-gate-is-ehos-app-s-tasks-a-hook-its-installer-writes-and-a-skill-an-assistant-runs.md)).
So a change to how the gate reads a command is made there, and tested there.

## How a change goes through it

1. **The review.** The author, a person or Claude Code, follows the `ehos-dev:pre-pr-review`
   skill, from the `ehos-dev` plugin, with this repository's part in
   [`.claude/review.md`](../../.claude/review.md): two reviews, one for correctness and one for
   security and performance, and every finding fixed, answered or filed. A change that is
   documentation alone, as `.claude/review.md` defines it, has its claims checked against the
   code instead. Then `mix check` passes in each package the change touches.
2. **The mark.** `mix review record`, run in `packages/review`, marks the commit checked out as
   reviewed. It refuses while the working tree has uncommitted changes, which the mark would not
   cover.
3. **The hook.** When Claude Code runs `gh pr create`, the hook in
   [`.claude/settings.json`](../../.claude/settings.json) runs `mix review gate` first, which
   refuses the command while `HEAD` carries no mark. Any new commit, amend or rebase leaves the
   new `HEAD` unmarked, so it needs a new review.
4. **CI.** Where the pull request lands, the `review` workflow
   ([`.github/workflows/review.yml`](../../.github/workflows/review.yml)) runs
   `mix review pull_request`, which fails while the description has no `## Review` section, or an
   empty one. It runs again whenever the description is edited.

## The commands

Each is run in `packages/review`. `record` and `check` act on the repository this package is in,
whichever worktree of it is checked out; `gate` checks the working tree the hook's command runs
in, its `cwd` or the directory the command changes into first; `pull_request` reads no
repository.

| Command | What it does | Fails |
| --- | --- | --- |
| `mix review record` | Marks `HEAD` as reviewed | With status 1, when the working tree has uncommitted changes, or a git command it runs fails (no repository, no `git`) |
| `mix review check` | Passes when `HEAD` is marked | With status 1, saying what to do, or when a git command it runs fails |
| `mix review gate` | Reads a Claude Code `PreToolUse` hook's input from standard input and decides it | With status 2, which makes Claude Code refuse the command and show why |
| `mix review pull_request` | Reads a pull request's description from `PULL_REQUEST_BODY` and checks it records the review | With status 1, saying what is missing |
| `mix review.changelog <from> <to>` | Checks that the commit `to` leaves the released versions' sections of every `packages/*/CHANGELOG.md` as `from` has them, unless it is that package's release | With status 1, naming each changelog, its line and the section it changes, or when git cannot compare the two commits |
| `mix review.plugins <from> <to>` | Checks that each commit from `from` to `to` that changes a plugin in `plugins/` gives it a version with no tag yet | With status 1, naming each plugin, its commit and its tag, or when the repository has no tags, or git fails |

```sh
cd packages/review
mix review record
PULL_REQUEST_BODY="$(cat body.md)" mix review pull_request
```

`mix help review` says the same, and `Review`'s docs (`h Review` in `iex -S mix`) what each
returns.

A mark is an empty file named after the commit, under `ehos-tools-review/` in the repository's
common git directory (`git rev-parse --git-common-dir`). It is never committed, and every
worktree of the repository sees it. Marks older than 90 days are removed when a new one is
recorded.

## The hook

`.claude/settings.json` runs a short shell command before every Bash call Claude Code makes. It
lets through at once any call whose input does not name `gh`, then `pr`, then `create` or `new`,
so the gate costs nothing for the rest. For the others it pipes the hook's input to
`mix review gate` in `packages/review`, and passes on its status: 0 runs the command, 2 refuses
it. If the gate cannot run at all (no `mix`, a compile error), the command is refused.

The gate refuses a command that opens a pull request, as `gh pr create` or its alias
`gh pr new` however spaced or continued, when:

- `HEAD` carries no mark;
- it names another branch or repository (`--head`, `--repo`, `GH_REPO`), since the mark covers
  the checked-out `HEAD` alone;
- before it opens the pull request, it moves `HEAD` (`git commit`, `checkout`, `switch`,
  `rebase`, `pull`, `merge`, `reset`, `am`, `cherry-pick`, `revert`, `bisect`, `filter-branch`,
  `update-ref HEAD`, `symbolic-ref HEAD <ref>`, `gh pr checkout`, `gh repo sync`) or points git
  elsewhere (`GIT_DIR=`, `GIT_WORK_TREE=`): the gate reads `HEAD` before the command runs, so what
  such a command sends is not what was reviewed;
- it changes directory before it opens the pull request in a way the gate cannot follow. A plain
  `cd ../worktree && gh pr create` is followed, and the tree it names is checked;
- it names `gh` and is longer than 64 KiB, or is too intricate for the gate's regexes to read.

It reads `gh pr` word by word, `gh` by any path: the word right after `pr` is gh's subcommand when
it is one of gh's, so `gh pr checkout new-feature` opens nothing. When a flag comes first, gh
takes it as the subcommand's, with a value of any shape (`gh pr --title "review it" create`), so
the command opens a pull request if `create` or `new` comes anywhere after `gh pr` in it.

### What it does not see

The gate reads shell text, so it guards against an honest mistake, not an adversary. It does not
see a pull request opened through the API (`gh api`) or by a tool other than Bash, a push to an
open pull request, a script, a Mix alias or a git alias that commits (open the pull request with
a command of its own), `update-ref` of the branch `HEAD` is on rather than of `HEAD`, or gh run
through a variable (`$g pr create`) or one of gh's own aliases: it knows gh by a word whose last
path component is `gh`. Whatever it would see, a call whose input does not hold `gh`, `pr` and
`create` or `new` in that order never reaches it: the hook lets that through first. CI checks
only that the description has something under `## Review`; no mark reaches it.

Of the commands the hook hands it, the gate fails closed: input it cannot read, a directory
change it cannot follow, a regex that gives up at its match limit, or a gate that does not run
refuses the command. The one way it fails open is the hook's timeout, 120 s, past which Claude
Code runs the command. The gate takes about 0.4 s, and 0.5 s on its first run, when it compiles.
It reads every command of up to 64 KiB we have tried, the ones built to slow it down included,
in under 0.2 s, so only a wait on Mix's build lock, while another `mix` holds it in
`packages/review`, could come near the timeout.

## The changelog check

A section below `## [Unreleased]` in a package's `CHANGELOG.md` is a release's notes, published
with its tag. When a package is released while a pull request that edits one of its
`[Unreleased]` lines is open, merging carries the edit into the new version's section, and the
notes then describe what the version does not do
([#583](https://github.com/EmpoweredHouse/ehos-tools/pull/583)). So CI's `changelog` check
([`.github/workflows/changelog.yml`](../../.github/workflows/changelog.yml)) runs
`mix review.changelog`, on a pull request's merge commit against its base, and on each push to
`main` commit by commit, for a release merged after a pull request's last run
([#585](https://github.com/EmpoweredHouse/ehos-tools/issues/585)).

Only a package's own release changes those sections: it renames `## [Unreleased]` to
`## [X.Y.Z] - YYYY-MM-DD` and sets `X.Y.Z`, with no `-dev`, in the package's `mix.exs`. When
`X.Y.Z` is above every version released before it, its section may appear above the others, and
nothing below it may change.
`Review.Changelog` holds the rule, and reads the repository through `Review.Git`. A change that
means to edit released notes, a repair among them, fails too: it is merged over the failure, with
the reason in its description.

```sh
cd packages/review
mix review.changelog origin/main HEAD
```

## The plugins' check

Claude Code caches a plugin by the `version` in its `.claude-plugin/plugin.json`. It keeps the
copy it has of a version, so a change released under a version that it has already cached
reaches nobody. A plugin's release is the tag `<plugin>-v<version>`, on the merge commit of the
pull request that raises the version (`CONTRIBUTING.md`, "Versions and releases"). So CI's
`changelog` check also runs `mix review.plugins`, on the same commits as `mix review.changelog`.

A commit fails when it changes `plugins/<plugin>/`, its `plugin.json` names a version that has
its tag, and the plugin's directory differs from the one at the tag. The commit that the tag
names passes, also when its run starts again after the tag. A commit between the raise and the
tag fails if its run starts again after the tag, because the check reads the tags of today. A
`plugin.json` that is not a JSON object, or whose `version` is not a string, fails too. The check reads the tags of the checkout, which the
workflow fetches. A checkout with no tags fails, because every version would then pass as new.
`Review.Plugins` holds the rule, and reads the repository through `Review.Git`.

```sh
cd packages/review
mix review.plugins origin/main HEAD
```

## Testing it

```sh
cd packages/review
mix deps.get
mix check
```

`mix check` is the gate every package here runs (`CONTRIBUTING.md`, "The gate"): the dependency
audit, formatting, compilation and tests with warnings as errors, Credo and Dialyzer. The tests
run real `git` in a throwaway repository of their own, but for `Review.Changelog`'s and
`Review.Plugins`', which replace `Review.Git` with a Hammox mock, and check what this package
gives the gate: its marks' directory, its messages, and the task's name; `Review.Changelog`'s
rule, in `test/review/changelog_test.exs`; and `Review.Plugins`' rule, in
`test/review/plugins_test.exs`. `test/docs_test.exs` fails on a
public function without a `@doc` and a `@spec`. What the gate refuses, and how a description is
read, are `EhosApp.Review`'s, tested in `packages/ehos_app/test/ehos_app/review_test.exs`.

To try the gate by hand, give it the input Claude Code would, from your own terminal: run by
Claude Code, the command would meet the hook itself first. A checkout path holding `"` or `\`
can make the JSON invalid, or name another directory, and the gate refuses either.

```sh
cd packages/review
echo '{"cwd": "'"$PWD"'", "tool_name": "Bash", "tool_input": {"command": "gh pr create --fill"}}' | mix review gate
echo $?
```

It prints why it refuses and exits with 2 while `HEAD` is unmarked, and exits with 0 once
`mix review record` has marked it.

## Where it comes from

It is ported from EHOS's `Ehos.Dev.Review`
([eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/lib/ehos/dev/review.ex)), and now
lives in `ehos_app` as `EhosApp.Review`, so an application and this repository share one gate.
