# The security and performance review

How the security and performance review of `ehos-dev:pre-pr-review` reads a change in eh-os,
ehos-tools or ehos_contract. It is given what the correctness review is given
([correctness.md](correctness.md), "What it is given"), and checks the same way that the files of
the range are the change.

This review needs no skill from outside the plugin. It reads the change itself.

## What it looks for

Only what this change adds or makes worse. A weakness the change does not touch is not a finding
here: list it under "Outside the change", for the author to settle at the procedure's step 6. The
review files nothing itself.

1. **The repository's list.** Each item of the part's "Security and performance". Mark each one in
   the report: a finding, checked and clean, or not touched by the change. No rule below takes an
   item of the list away.
2. **Input.** Input from a person, a request, a webhook, a file or another system, followed to
   where it is used: an Ecto `fragment` or a raw query, a command (`System.cmd`, a port, a shell
   line), a path on disk, a URL that is fetched, `String.to_atom/1`, `:erlang.binary_to_term/1`,
   `Code.eval_*`, a template, HTML that is not escaped (`raw/1`).
3. **Who may do it.** Authentication and authorization: a route or action without the check its
   neighbours have, a scope that is not passed to the context, a role that grants more than its
   name, a session or token that lives too long or is not checked.
4. **Secrets and trust.** A secret in the code, in a log line, in an error message, in what a
   generated project commits, or in a CI log; a certificate or name that is not checked; a
   dependency or action pinned by a tag, which can move, where a commit is needed; data fetched
   and trusted without a check of its size or shape.
5. **What is shown.** A person's data or a credential in a log, an error, a response or a page that
   does not need it; a cookie without `Secure`, `HttpOnly` or `SameSite` where it carries a
   session.
6. **Text that an assistant reads.** Output that reaches a model as instructions (a hook's output,
   a message that tells an assistant which command to run) built from a value that a file or a
   request controls.
7. **Performance.** Work without a bound (a list, a read, a retry, a queue that grows), work
   repeated on each request, each start or each run of an installer, a query in a loop, a missing
   index for a new query, a blocking call on a hot path, a call to a program or the network without
   a time limit.

## What it does not report

These make noise, not findings:

- an attack that needs control of the environment variables or the command line of a program
  that a person runs by hand: that person has them already. In a CI workflow, a hook, or a project
  that ehosctl generates, a value from event data (a pull request's description, title or branch),
  from a file of the repository, or from a command an assistant builds is input: item 2 covers it;
- a UUID guessed by an attacker;
- a URL in a log, or data that is not a secret and not a person's;
- a test or test support file, unless it puts a secret or a person's data in the repository or
  in a CI log;
- a hardening idea with no path to harm in this change. If the repository's list names it, it is
  not an idea: it is item 1.

## How it writes and checks a finding

As [correctness.md](correctness.md) says, with one more field: **the path to harm**, the steps an
attacker or a load takes from input they control to the harm. A finding of the list's item that
has no such path is still reported, as the list asks.

## The report

The report opens with the skills the review invoked, and any it could not. Then it gives the list
of item 1, each item marked. Then the findings, the heaviest first, each with where, what, the
scenario, the path to harm, the weight and the verdict. Then the refuted findings, and the
weaknesses outside the change. If there is no finding, the report says "no findings".

The review changes nothing and commits nothing.
