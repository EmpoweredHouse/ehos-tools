# The report

What `ehos-dev:triage-follow-ups` writes at step 7, to the session's scratchpad and never to the
repository: a follow-up may hold detail of a private repository.

## Its sections, in order

1. **The queue.** Open follow-ups today; opened and closed per week over the last eight weeks; one
   sentence on whether it grows.
2. **Urgent.** Each urgent issue: number, title, why it is urgent, the date if it has one.
3. **To close.** One row per _settled_, _stale_ and _same cause_ issue that its check upheld:
   number, title, verdict, evidence, and the comment it will be closed with. The user approves from
   this table.
4. **Partly settled.** Number, title, what is done with its evidence, what is left. The comment
   says what is left; the issue stays open.
5. **Fixes.** Each fix: the package, the issues it closes, the cause they share, its size (a few
   lines, a day, more), urgent or not. In the order of step 6.
6. **Live, not in a fix.** Number and title, by area.
7. **Broken verdicts.** Each verdict the check broke: what was claimed, what is still live. These
   show where the first reading goes wrong.

Every open follow-up appears in exactly one of sections 3 to 6.

## The comment an issue is closed with

In English, plain, and short enough to read in the issue's timeline. It names the evidence by link,
so a reader can check the close without asking.

- **settled:** "Settled on `main` by <pull request or commit link>: <one line on what it changed>.
  <The file or test that shows it, linked at the commit>. Closed by a triage of the follow-ups."
- **stale:** "No longer applies: <what was removed or replaced>, in <link>. Closed by a triage of the
  follow-ups."
- **same cause:** close with `--duplicate-of <kept issue>` and the comment "Same cause as #<kept>:
  <the place in the code both name>. The fix is tracked there."
- **partly settled**, a comment only: "Partly settled by <link>: <what is done>. Still open for:
  <what is left>."

A link to a file names the commit, not `main`, so it keeps pointing at what was checked.
