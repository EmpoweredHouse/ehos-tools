---
name: write-adr
description: Write, supersede or change the status of a decision record in eh-os (D-xx) or ehos-tools (T-xx), in docs/adr/. Use before merging code that depends on a decision that would cost more than a day to reverse or where a reasonable engineer could have chosen differently — a library that becomes part of the public surface or the security model, a data model or wire format others rely on, how something is pinned, versioned or released, a deliberate trade-off against a requirement or the architecture — and whenever the user asks to record, document or revisit a decision. Not for eh-os-contract, whose docs/adr/ holds dated amendments, not records; not for gaps, bets or open questions, which stay where the repository keeps them.
---

# Writing a decision record

The reader is a technical person who was not in the room and is deciding whether to trust what
was built. Write for them: what forced the decision, what was really on the table, what we gave up.

## First, read what this repository owns

Read the section "Writing a record" in `docs/adr/README.md` at the root of the repository you are
working in. It is the repository's half of this procedure, and wins where the two differ. It says:

- **the prefix** and how a number maps to a file (`0027-…` is `D-27`), and any records kept
  outside `docs/adr/` that share the numbering;
- **whose decision it is**, when another repository keeps records too;
- **where to search** before writing, and **what constrains** a decision: the documents a new
  record must not contradict silently;
- **what a Confirmation cites**: the repository's test or check identifiers;
- **how to link** within the repository and to others;
- **what follows a new record**: the index rows to add, the checks to run.

If the file or the section is missing, this repository does not keep records this way (eh-os-contract
keeps dated amendments in `docs/adr/`): stop and say so, rather than taking another repository's
answer.

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

1. **Number.** The next free number after the highest the section names. File name
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
- `accepted` once the user agreed; name them in `decision-makers`.
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
   ("Decided under #201"), and the issue's "Decision records" section, or a comment on it, names the
   record with its status (`ehos-dev:stage-issue`). Once the user accepts it, that is a comment on
   the issue too. The discussion stays on the issue; the record keeps the options and the outcome.
5. Everything in English.
