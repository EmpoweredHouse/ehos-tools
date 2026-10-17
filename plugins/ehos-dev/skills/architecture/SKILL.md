---
name: architecture
description: Keep eh-os's architecture current with a change made in eh-os, ehos-tools or eh-os-contract — the pages in docs/architecture/ and docs/ARCHITECTURE.md, each concept's badge in maturity.yml, the glossary and the diagrams (eh-os D-106, D-107). Use when a decision record is written or its status changes, when a step or a stage closes, before a pull request that changes what the architecture names (a part, a boundary and what crosses it, a mechanism, a property, how real something is), and when the user asks to update the architecture. Not for reference pages, how-to or reasons, which the architecture links and never restates, and not for ehos-tools' or eh-os-contract's own documentation.
---

# Keeping the architecture current

eh-os's architecture describes EHOS and the components it is delivered through in three levels: the
top page, an area, a concept, each concept with a badge saying how real it is (eh-os
[D-106](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0106-the-architecture-is-described-in-three-levels-as-its-parts-and-their-maturity-and-everything-else-is-linked.md)).
The single document it replaced went stale because the sessions that changed EHOS did not change
it: it called settled what records had only proposed, and open what they had decided, and nobody
noticed until an audit read all of it. This skill is the step that keeps the pages moving with the
code, run by the session that makes the change.

## First, read what eh-os owns

Read the section "Keeping the architecture current" in eh-os's `CONTRIBUTING.md`: in an eh-os
checkout, or at <https://github.com/EmpoweredHouse/eh-os/blob/main/CONTRIBUTING.md> from another
repository. It is eh-os's half of this procedure and wins where the two differ. It says:

- where the top page, the areas, the concepts, the glossary, the badges and the diagram sources are;
- the rules a badge follows, and what makes each one true;
- what D-106 lets into the architecture, and what it sends elsewhere;
- which checks hold the pages, and how to run them.

If the section is missing, stop and ask the user rather than guessing where the pages are.

## Where the change is made

- **In eh-os**, the pages change in the same pull request as the change, so the two are reviewed
  together and merge together.
- **In ehos-tools or eh-os-contract**, which keep no architecture of their own, the pages are
  eh-os's. Make the eh-os change in a pull request of its own, from an eh-os checkout, and link it
  from this repository's pull request and issue. When it cannot be written yet, because what it
  describes is not merged or released, open an eh-os issue (the "Follow-up" template, label
  `follow-up`) naming the pages and what will change in them, and say so in this pull request.

## Steps

1. **Say what changed, in the architecture's terms**: a part, a boundary and what crosses it, a
   mechanism, a property, or how real something is. A change that alters none of them, a command, a
   field, a number, a how-to or a status, changes no page; say so in one line to whoever called
   this skill, and stop. The test is D-106's: a sentence belongs if it would still be true, and still
   worth saying, were every command, field name and number around it to change.
2. **Find the pages it touches.** Search `docs/architecture/` and `docs/ARCHITECTURE.md` for the
   record's id, the component's name, the glossary words the change is about and the concepts'
   titles; read `maturity.yml`'s `records` lists and the diagram sources' headers (`parts`,
   `words`). A change to what an area holds together, or to what it does not protect against,
   reaches the area page and sometimes the top page.
3. **Read each page whole, and the code it describes, before changing a sentence.** Say the target
   first and, where what runs differs, what runs and how it falls short. Link the record, the
   reference page or the issue; never restate them, and never name a stage outside a link. A claim
   about who can read, write, sign or reach something is checked against the code, the chart and the
   cluster's permissions before it is written: every review of these pages has found one that said
   more protection than holds.
4. **Move a badge only where the change makes it true**, by the rules in eh-os's section: Built
   names merged work; Decided names accepted records, so a proposed record moves no badge; Interim
   only where a record names how what runs departs from the target. A record that is accepted,
   superseded or rejected changes the `records` lists that cite it, and may change the badge.
5. **Glossary first.** A new word, or a word whose meaning changes, goes in the glossary before a
   page uses it. The words the glossary says are never shown alone stay so.
6. **Diagrams.** When a part, a connector, a label or a part's maturity changes, edit the source,
   generate the outputs, and look at the rendered image in both themes.
7. **Run the checks** eh-os's section names, each one's own exit code, and fix what they report.
8. **Say what you changed and what you left**: the pages, the badges moved and why, the diagrams;
   and each page you read and left unchanged, with the reason in one line. This goes in the pull
   request's description and on the issue that holds the work.

## Who calls it

- `ehos-dev:write-adr`, when a record is written and when its status changes.
- `ehos-dev:stage-issue`, before the pull request that finishes a step or a stage.
- `ehos-dev:pre-pr-review`, before its reviews, on a change that touches what the architecture
  names, so that the reviews read the pages with the code.

## What reviews of these pages keep finding

Look for these on purpose; each one happened while the architecture was rewritten.

- A page that says more protection than holds: about the governance plane, the operator, the
  cluster's controllers, the installation administrator, or what a workload is given.
- A summary page, the top page or an area's, that contradicts the concept page it summarises.
- A badge moved by a record that is only proposed, or Built without the merged work that makes it.
- A glossary word shown alone, or a page using a word the glossary does not hold.
- A link that lands on a page that does not hold what the sentence around it refers to.
