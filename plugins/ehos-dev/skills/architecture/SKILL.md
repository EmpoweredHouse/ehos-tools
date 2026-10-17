---
name: architecture
description: Keep eh-os's architecture current with a change made in eh-os, ehos-tools or eh-os-contract — the pages in docs/architecture/ and docs/ARCHITECTURE.md, each concept's badge in maturity.yml, the glossary and the diagrams (eh-os D-106, D-107). Use when a decision record is written or its status changes, when a step or a stage closes, before a pull request that changes what the architecture names (a part, a boundary and what crosses it, a mechanism, a property, how real something is), and when the user asks to update the architecture. Not for reference pages, how-to or reasons, which the architecture links and never restates, and not for ehos-tools' or eh-os-contract's own documentation.
---

# Keeping the architecture current

eh-os's architecture describes EHOS and the components it is delivered through in three levels: the
top page, an area, a concept, each concept with a badge saying how real it is (eh-os D-106). The
single document it replaced went stale because the sessions that changed EHOS did not change it: it
called settled what records had only proposed, and open what they had decided, and nobody noticed
until an audit read all of it. This skill is the step that keeps the pages moving with the code, run
by the session that makes the change.

## First, read what eh-os owns

Read the section "Keeping the architecture current" in eh-os's `CONTRIBUTING.md`: in eh-os, on the
branch the change is on. From another repository, read it from a local eh-os checkout of
`origin/main`, which the change needs anyway, or with the command below; eh-os is private, so a
plain web fetch of it fails.

```bash
gh api repos/EmpoweredHouse/eh-os/contents/CONTRIBUTING.md -H "Accept: application/vnd.github.raw"
```

The section says:

- where the top page, the areas, the concepts, the glossary, the badges and the diagram sources are;
- the rules a page and a badge follow;
- which checks hold the pages, and how to run them.

It wins over this skill on those three things, and on nothing else: it never relaxes a review gate,
the rule that only the user accepts a record, or another rule of the repository the change is in. If
the section is missing, stop and ask the user rather than guessing where the pages are.

## Where the change is made

- **In eh-os**, the pages change in the same pull request as the change, so the two are reviewed
  together and merge together.
- **In ehos-tools or eh-os-contract**, the pages are eh-os's: neither keeps EHOS's architecture
  (eh-os-contract's `docs/adr/architecture.md` is the premise of its own design). Make the eh-os
  change in a pull request of its own from an eh-os checkout, reviewed there with
  `ehos-dev:pre-pr-review` and eh-os's `.claude/review.md`, which reviews `docs/architecture/` like
  code; link it from this repository's pull request and issue. When it cannot be written yet,
  because what it describes is not merged or released, open an eh-os issue from the "Follow-up"
  template, label `follow-up`, under the milestone of the stage or track the work belongs to,
  naming the pages, what will change in them, and the merge or release that unblocks it; say so in
  this pull request.

## Steps

1. **Say what changed, in the architecture's terms**: a part, a boundary and what crosses it, a
   mechanism, a property, or how real something is. A change that alters none of them, a command, a
   field, a number, a how-to or a status, changes no page; say so in one line to whoever called
   this skill, and stop. An accepted eh-os record of that kind still says `Not architecture` in its
   row's Area column of eh-os's `docs/adr/README.md`, or the check fails it. The test is D-106's: a sentence belongs if it would still be true, and still
   worth saying, were every command, field name and number around it to change.
2. **Find the pages it touches.** Search `docs/architecture/` and `docs/ARCHITECTURE.md` for the
   record's id, the component's name, the glossary words the change is about and the concepts'
   titles; read `maturity.yml`'s `records` lists and the diagram sources' headers (`parts`,
   `words`). A change to what an area holds together, or to what it does not protect against,
   reaches the area page and sometimes the top page.
3. **Read each page whole, and the code it describes, before changing a sentence.** Say the target
   first and, where what runs differs, what runs and how it falls short. Link the record, the
   reference page or the issue; never restate them, and never name a stage outside a link.
   - **A proposed record decides nothing yet.** A page describes its design only as planned, under
     a concept marked Planned or as one line naming the record as proposed, never as the target or
     as what runs. Once the record is accepted, its decision becomes the target.
   - **A claim about who can read, write, sign or reach something** cites the code, chart, policy or
     test that shows it, or the issue that says it does not hold. Check every place that can grant
     or refuse it, not only the one the change touched: the cluster's roles and admission policies,
     OpenBao's policies, the database's grants and who runs migrations, the log store's credential,
     network rules and what has none, the controllers the installation brings beyond the chart,
     backups and the installation administrator. Ask both what an interface returns and what a
     compromised component can have another do for it. eh-os's
     `docs/architecture/authority/enforcement-points.md` and
     `docs/architecture/cross-cutting/governance-plane-trust.md` list where this went wrong before:
     every review of these pages found a sentence saying more protection than holds.
4. **Move a badge only where the change makes it true**, by the rules in eh-os's section and the
   header of `maturity.yml`:
   - **Built** cites merged work: a stage's evidence, a release, or a merged pull request. To cite the
     pull request that makes it so, open it as a draft, then add its number in a commit of its own,
     which goes through `ehos-dev:pre-pr-review` again before it is pushed; or cite the stage once its
     evidence exists.
   - **Building** cites the plan whose step is under way, and **Decided** accepted records only.
   - **Planned** cites a plan, a ROADMAP section or a proposed record, and **Idea** a plan or ROADMAP
     only.
   - **Open** cites gaps that `docs/ADR.md` holds open.
   - **Interim** qualifies Built, and cites the record that names how what runs departs.

   A record that is accepted, superseded or rejected changes the `records` lists that cite it and
   may change the badge. For an eh-os record that is the same commit as the status change, since
   `mix ehos.gen.diagrams --check` fails a Decided concept that cites a record no longer accepted,
   and a Planned one that names no plan or ROADMAP section once none of its records is still
   proposed; it lets the other cases of a status change pass, so they are the author's to catch. A record in another
   repository changes the pages through the eh-os change above.

   A concept's Maturity, Records and Known gaps lines, and its area page's table, are generated from
   `maturity.yml` between `<!-- generated: … -->` and `<!-- /generated -->`: change the file and
   run `mix ehos.gen.diagrams`, never the region. An accepted eh-os record is cited by some
   concept's `records`, or says `Not architecture` in its row's Area column of eh-os's
   `docs/adr/README.md`, and then no concept cites it; an open gap is cited by some concept's
   `gaps`. The check fails each of these left undone. The section's table under "When you change
   something" says for each kind of change what to write and which check fails without it.
5. **Glossary first.** A new word, or a word whose meaning changes, goes in the glossary before a
   page uses it. The words the glossary says are never shown alone stay so.
6. **Diagrams.** When a part, a connector, a label or a part's maturity changes, edit the source,
   generate the outputs, and look at the rendered image in both themes.
7. **Run the checks** eh-os's section names, each one's own exit code, and fix what they report.
8. **Say what you changed and what you left**: the pages, the badges moved and why, the diagrams;
   and each page you read and left unchanged, with the reason in one line. This goes in the pull
   request's description and on the issue that holds the work.

## Who calls it

Once per change: a caller that finds it already run for the same commits uses that report, and a
fix commit that changes what the pages describe runs it again.

- `ehos-dev:write-adr`, when a record is written and when its status changes.
- `ehos-dev:stage-issue`, before the pull request that finishes a step, and when a stage closes,
  since a stage's evidence is what lets a concept cite it as Built.
- `ehos-dev:pre-pr-review`, before its reviews, on a change that touches what the architecture
  names, so that the reviews read the pages with the code.

## What reviews of these pages keep finding

Look for these on purpose; each one happened while the architecture was rewritten.

- A page that says more protection than holds: about the governance plane, the operator, the
  cluster's controllers, the installation administrator, or what a workload is given.
- A summary page, the top page or an area's, that contradicts the concept page it summarises.
- A proposed record described as decided, a badge it moved, or Built without the merged work that
  makes it.
- A glossary word shown alone, or a page using a word the glossary does not hold.
- A link that lands on a page that does not hold what the sentence around it refers to.
