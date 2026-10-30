---
name: write-adr
description: Use before merging code that depends on a decision costing more than a day to reverse, or where a reasonable engineer could have chosen differently (a public library, a data model or wire format, how something is pinned or released, what an installer does to a project, a trade-off against the architecture), and when the user asks to record or revisit one — writes, supersedes or changes the status of a record in eh-os (D-xx) or ehos-tools (T-xx). Not for eh-os-contract, nor for gaps or open questions.
---

# Writing a decision record

The reader is a technical person who was not in the room and is deciding whether to trust what
was built. Write for them: what forced the decision, what was really on the table, what we gave up.

## First, read what this repository owns

Read the section "Writing a record" in `docs/adr/README.md` at the root of the repository you are
working in. It is the repository's half of this procedure, and wins where the two differ on the
items below; "Status" and "Superseding" hold in every repository whatever it says. That section
says:

- **the prefix** and how a number maps to a file (`0027-…` is `D-27`), and any records kept
  outside `docs/adr/` that share the numbering;
- **whose decision it is**, when another repository keeps records too;
- **where to search** before writing, and **what constrains** a decision: the documents a new
  record must not contradict silently;
- **what a Confirmation cites**: the repository's test or check identifiers;
- **how to link** within the repository and to others;
- **what follows a new record**: the index rows to add, the checks to run.

If the file or the section is missing, this repository does not keep records this way: stop and say
so, rather than taking another repository's answer. This skill does not apply in eh-os-contract,
whatever its `docs/adr/` holds: there, an assumption that turned out wrong or a changed rule of the
contract is a dated amendment to a document in `docs/adr/`, linking the issue, and anything else
goes where its `CLAUDE.md` says.

## Before writing

1. **Check it is not already decided.** Search where the section says. If an existing decision
   covers it, cite it instead; if the new one changes it, this is a supersession (below).
2. **Read what constrains it.** A decision that goes against one of those documents says so
   explicitly and explains why the document should change, and the same pull request changes it, or
   files the change where the document lives.
3. **Verify facts you are about to state.** Library versions and capabilities on hex.pm or in the
   source, behaviour of our own code in the code. Earlier findings and experiments are cited by
   where they are (a path, a commit, an issue), not paraphrased from memory.

## Writing it

1. **Number.** The next free number after the highest in `docs/adr/` and in any other place the
   section says shares the numbering; list them, do not trust an index alone. File name
   `docs/adr/NNNN-short-title.md`, zero-padded. Numbers are never reused, including for rejected or
   superseded records.
2. **Start from [template.md](template.md)** (MADR 4.0, trimmed). Put the repository's prefix in
   the title (`D-27 · …`, `T-03 · …`), and fill the front matter: `status`, today's `date`,
   `decision-makers`.
3. **Title** states the decision as a sentence, not the topic: "EHOS signs people in and issues the
   credentials applications verify locally", not "Identity"; "ehos_app pins a GitHub dependency to
   a commit, not to its tag", not "Pinning".
4. **Considered options** are the ones really considered. Two options where one is a straw man is a
   justification, not a record.
5. **Consequences** include the bad ones, each with its mitigation if there is one. A record with
   only benefits was written to win an argument.
6. **Confirmation** names the test, check or measurement that would fail if the decision stopped
   holding, by the identifier the section names where there is one. If none exists yet, say what
   must be written.
7. **Link** as the section says: within the repository by relative path, to another repository by
   its GitHub URL, never a local path.

## Status

- `proposed` when the user has not explicitly agreed. Never mark a decision `accepted` on your own
  judgement; ask. Code depending on a proposed decision waits.
- `accepted` once the user agreed; name them in `decision-makers`. A change of status runs
  `ehos-dev:architecture` ("After writing").
- `rejected`, `deprecated`, or `superseded by <prefix>-NN`.

## Superseding

An accepted record is never rewritten. Write a new record that explains what changed and why, then
edit the old one in exactly two places: its status becomes `superseded by <prefix>-NN`, and one line
under the title points to the new record.

## After writing

1. Do what the section's "what follows a new record" says: the index row in `docs/adr/README.md`,
   and any other table it names.
2. Check that every relative link in the record resolves.
3. Where code implements the decision and the reason is not obvious from the code, cite it in a
   comment: `# D-24: tokens are verified locally, never introspected`.
4. When the decision was made under an issue, the record's "More information" says so first
   ("Decided under #201"), and both the issue's section that lists its records (in eh-os, "Decision
   records") and a comment on the issue name the record with its status (`ehos-dev:stage-issue`).
   Once the user accepts it, that is a comment on the issue too. The discussion stays on the issue;
   the record keeps the options and the outcome.
5. **Keep eh-os's architecture current** with `ehos-dev:architecture`: the pages, badges and
   diagrams the record touches change in the same pull request in eh-os, or through an eh-os pull
   request or issue from another repository. A proposed record changes no page's target: a page
   names it as planned until it is accepted. Run the skill again when the record's status changes,
   since an accepted, superseded or rejected record can move a badge and changes the lists that cite
   it; for an eh-os record, in the same commit as the status change.
6. Everything in English.
