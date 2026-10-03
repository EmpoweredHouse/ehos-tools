---
status: accepted
date: 2026-10-03
decision-makers: [Emil Wojtaszek]
consulted: []
---

# T-01 · ehos-tools keeps its own decision records, numbered T-xx, beside EHOS's D-xx

## Context and problem statement

ehos-tools is meant to be open-sourced, and has to make sense to someone who was not in the room.
Its early choices (Burrito, Igniter, mise, a Homebrew tap) are argued in
[`docs/research.md`](../research.md), and its open questions are listed in
[`docs/spike.md`](../spike.md). Every decision since has been recorded in EHOS's repository instead,
as a `D-xx` ([eh-os D-72](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0072-the-design-system-is-a-library-ehos-design-kept-in-ehos-tools.md)
put the design system here), or only in commit messages and pull requests: that `ehos_app` pins a
GitHub dependency to a commit rather than a tag, that a developer's declined design system is never
brought back, that a project from 0.2 is upgraded by running the installer again.

A reader of ehos-tools alone cannot find those, and a reader of EHOS has to wade through choices
about a CLI's release process. The `write-adr` skill, brought over from EHOS, needs a place to
write.

## Decision drivers

- A reader of this repository finds why it is the way it is without leaving it.
- One decision has one record: nothing is decided twice, in two places that can disagree.
- EHOS's numbering stays EHOS's: `D-72` means the same thing wherever it is cited.

## Considered options

1. Records in ehos-tools, `docs/adr/`, numbered `T-xx`
2. Records in eh-os, sharing its `D-xx` numbering
3. No records: `docs/research.md` and pull requests only

## Decision outcome

Chosen option: **"Records in ehos-tools, numbered `T-xx`"**, because it is the only one a reader
of this repository alone can follow, and its own prefix keeps a `T-03` from being mistaken for
EHOS's `D-03`. A decision about what EHOS requires of an application stays a `D-xx` in eh-os;
the `write-adr` skill says which is which.

### Consequences

- Good, because the reasons behind the tool ship with the tool, and stay readable once it is
  public and eh-os is not.
- Bad, because two sets of records can overlap: a choice in ehos-tools that EHOS also relies on
  has to be placed in one. Mitigated by the skill's rule that EHOS's record decides and a `T-xx`
  records only what ehos-tools does about it.
- Neutral: `docs/research.md` keeps the choices made before this record. A revisited one gets a
  `T-xx` that supersedes it.

### Confirmation

The index in [`README.md`](README.md) lists every file in this directory, and every record's
relative links resolve. No test checks either yet.

## Pros and cons of the options

### Records in ehos-tools, numbered `T-xx`

- Good, because the repository explains itself.
- Bad, because a reader has to know there are two series.

### Records in eh-os, sharing `D-xx`

- Good, because there is one series and one index.
- Bad, because ehos-tools would be explained by a repository its readers may not be able to open,
  and EHOS's records would fill with a CLI's release details.

### No records

- Good, because nothing new to keep.
- Bad, because decisions already made live only in commit messages, and come back as questions.

## More information

Revisit if ehos-tools moves into eh-os, or EHOS's records become public alongside it.
