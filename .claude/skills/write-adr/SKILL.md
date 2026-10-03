---
name: write-adr
description: Write, supersede or change the status of an ehos-tools decision record (T-xx) in docs/adr/. Use before merging code that depends on a decision that would cost more than a day to reverse or where a reasonable engineer could have chosen differently — a library or tool the CLI or the template is built on, what the installer does to a project it did not create, how a package is pinned, versioned or released, a deliberate trade-off against something EHOS or CONTRIBUTING.md asks — and whenever the user asks to record, document or revisit a decision. Not for decisions about EHOS itself (what an application must be, ehos.yaml, sign-in), which are EHOS's D-xx records in eh-os; not for open questions and guesses, which stay in docs/spike.md.
---

# Writing an ehos-tools decision record

The reader is a technical person who was not in the room and is deciding whether to trust the
tool. Write for them: what forced the decision, what was really on the table, what we gave up.

## Whose decision is it

ehos-tools keeps its own records, numbered `T-01`, `T-02`, … in `docs/adr/`
([T-01](../../../docs/adr/0001-ehos-tools-keeps-its-own-decision-records.md)). EHOS keeps its
own, numbered `D-xx`, in [eh-os's `docs/adr/`](https://github.com/EmpoweredHouse/eh-os/tree/main/docs/adr).

- A decision about how ehos-tools is built, released or behaves toward a developer is a `T-xx`.
- A decision about what EHOS requires of an application, or that EHOS's own components rely on
  (the design system's place, eh-os D-72; sign-in, D-64), is a `D-xx`, written in eh-os with
  that repository's `write-adr` skill. Here it is cited as `eh-os D-xx`, linked by its GitHub URL.
- When both apply, EHOS's record decides and the `T-xx` records only what ehos-tools does about it.

## Before writing

1. **Check it is not already decided.** Search `docs/adr/` here, `docs/research.md` ("Decisions
   and why", the choices made before these records began) and EHOS's decisions for the topic. If
   an existing decision covers it, cite it instead; if the new one changes it, this is a
   supersession (below). A choice in `docs/research.md` that is revisited gets a `T-xx` that
   supersedes it, and `docs/research.md` points to that record.
2. **Read what constrains it.** `CONTRIBUTING.md`, `AGENTS.md`, `docs/spike.md` ("Open"), and
   EHOS's specification ([ARCHITECTURE.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ARCHITECTURE.md),
   [ROADMAP.md](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/ROADMAP.md)). A decision
   that goes against one of them says so explicitly and explains why it should change, and the
   same pull request changes it, or files the change in eh-os.
3. **Verify facts you are about to state.** Library versions and capabilities on hex.pm or in the
   source, behaviour of our own code in the code. Earlier findings are cited by where they are
   (`docs/spike.md`, a commit, an issue), not paraphrased from memory.

## Writing it

1. **Number.** The next free number after the highest in `docs/adr/`. File name
   `docs/adr/NNNN-short-title.md`, zero-padded; `0003-…` is `T-03`. Numbers are never reused.
2. **Start from [template.md](template.md)** (MADR 4.0, trimmed). Fill the front matter: `status`,
   today's `date`, `decision-makers`.
3. **Title** states the decision as a sentence, not the topic: "ehos_app pins a GitHub dependency
   to a commit, not to its tag", not "Pinning".
4. **Considered options** are the ones really considered. Two options where one is a straw man is a
   justification, not a record.
5. **Consequences** include the bad ones, each with its mitigation if there is one. A record with
   only benefits was written to win an argument.
6. **Confirmation** names the test, check or CI job that would fail if the decision stopped
   holding (`Ehosctl.TemplateTest`, the installer's idempotency test, the `e2e` job). If none
   exists yet, say what must be written.
7. **Link** within the repository with relative paths
   (`../spike.md#open-decisions-this-spike-cannot-make`, `../../CONTRIBUTING.md`), and to other
   repositories by their GitHub URL, never a local path.

## Status

- `proposed` when the user has not explicitly agreed. Never mark a decision `accepted` on your own
  judgement; ask. Code depending on a proposed decision waits.
- `accepted` once the user agreed; name them in `decision-makers`.
- `rejected`, `deprecated`, or `superseded by T-xx`.

## Superseding

An accepted record is never rewritten. Write a new record that explains what changed and why, then
edit the old one in exactly two places: its status becomes `superseded by T-xx`, and one line under
the title points to the new record.

## After writing

1. Add a row to the index in `docs/adr/README.md`.
2. Check that every relative link in the record resolves.
3. Where code implements the decision and the reason is not obvious from the code, cite it in a
   comment: `# T-02: pinned to the commit, since a tag can be moved`.
4. Everything in English.
