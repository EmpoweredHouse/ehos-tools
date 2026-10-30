---
name: diagrams
description: Before you add or change a diagram in documentation about EHOS — an architecture overview, a flow, a sequence, the states of one thing — choose the one question it answers and its type, lay it out with the method of the `diagram-design` plugin within the budget, use the words of the glossary that owns each label, and say in the text what the picture says. In eh-os, write the SVG source and generate it with `mix ehos.gen.diagrams`. Use with `ehos-dev:voice`, which says when a page needs a picture. Do not use for the contract graph that `eh_os_contract_graph` draws from data, nor for a screen of the console.
---

# Drawing a diagram for EHOS documentation

A good diagram shows what a reader cannot easily get from sentences: what runs beside what, what
goes where, in which order. The eh-os decision record D-107 decided how EHOS draws diagrams:
<https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0107-architecture-diagrams-are-svg-files-generated-by-mix-from-hand-laid-sources-and-skinned-by-ehos-design.md>.
This skill tells you how to do it. If this skill and D-107 do not agree, D-107 is correct: tell the
user.

## Two tools, two jobs

| Tool | Job | Where |
| --- | --- | --- |
| `diagram-design:diagram-design` | **Lay out the diagram**: the type, the placement of the parts, the connectors, the key | the `diagram-design` plugin (Cathryn Lavery, MIT), which the `ehos-tools` marketplace lists at one commit |
| `mix ehos.gen.diagrams` | **Check the source and give it the look of EHOS**: the words, the budget, the colours and fonts of `ehos_design`, both themes | eh-os only, for now |

1. **Load `diagram-design:diagram-design` before you lay out a diagram.** Use its method for the
   layout. If it is not available, tell the user. Do not enable it yourself: it is third-party code,
   and `.claude/settings.json` is shared by every contributor.
2. **Use only its layout method and its references.** Do not run its onboarding, its profiles, its
   commands or its scripts (export, import, doctor). When it asks about a style guide, choose to keep
   the default: the look comes from the generator.
3. **Use the rules of this skill where they differ from diagram-design.** This skill gives the types,
   the budget, the words and the look of EHOS. Do not commit its HTML, PNG or styled SVG output.
4. **Write the source of EHOS yourself**, with the classes of the skin (below), from the layout that
   you made.

## When to draw

Draw a diagram when the text describes one of these:

- parts and the connections between them;
- an order of steps between two or more actors;
- the states of one thing;
- a flow of information or of a decision.

Do not draw a diagram:

- to decorate a page;
- for a list that a table shows better;
- when a diagram with the same question exists: link to it.

## One diagram answers one question

Choose the type from the question. Each type has one look, so the reader learns it one time. A new
type needs a change to D-107.

| Question | Type |
| --- | --- |
| What runs beside what, and what crosses between them? | Architecture |
| What contains what? | Nested |
| What depends on what? | Dependency graph |
| Where does it run? | Deployment |
| Who talks to whom, in order? | Sequence |
| Who does what across roles? | Swimlane |
| What states does one thing pass through? | State machine |
| Where does information flow and change? | Data flow |
| Which entities relate? | ER |
| Where is each control enforced? | Layer stack |
| How is it judged? | Flowchart |
| What is the whole loop? | Loop |

Write the question as the title of the diagram, or as a sentence that states the answer: "EHOS runs
beside the applications of the client".

## The rules of the picture

1. **Budget: 9 parts or fewer, 12 connectors or fewer.** If you need more, draw an overview and a
   detail.
2. **One accent.** One part carries the accent: the part that the diagram is about.
3. **The layout shows the meaning.** Put the parts where the answer is visible. Example: if EHOS runs
   beside the applications, draw it beside them, not under them.
4. **Connectors are orthogonal**: horizontal and vertical lines only. The ring of a Loop is the one
   exception.
5. **Put an opaque mask under each label** of a connector, so that no line goes through the text.
6. **Number the connectors.** Under the figure, write a key: one sentence for each number.
7. **A dashed connector means optional or asynchronous.** It means nothing else.
8. **Maturity is the outline of a part**, never of a connector:

   | Maturity | Outline |
   | --- | --- |
   | Built | solid |
   | Building, Decided | solid, with a tag that names the badge |
   | Planned, Idea | dashed, with a tag |
   | Open | grey, with a tag |

9. **Add a legend strip** that names each kind of part and connector the diagram uses.
10. **The fonts are Albert Sans for words and JetBrains Mono for technical labels.** The colours come
    from `ehos_design`, in the light theme and in the dark theme.

## The words

1. **Each label is a word of the glossary that owns it**, or a technical name that the source lists as
   technical. `ehos-dev:voice`, "The words", gives the owners.
2. **The label of a connector is a verb**: "submits", "grants", "records".
3. **Obey the list of words that are never alone**: "role binding", never "binding".
4. **The text of the page and the key use the same words as the picture.** The picture and the text
   say the same thing.
5. **Give each diagram a title and a description of one sentence.** The description is the
   alternative text: a reader who cannot see the picture gets the answer from it.

## In eh-os

| Piece | Path |
| --- | --- |
| Source, laid out by hand | `docs/architecture/diagrams/<id>.svg` |
| Output, generated; do not edit | `docs/architecture/img/<id>.svg` |
| The page that shows it | `docs/architecture/**.md`, as `![<description>](…/img/<id>.svg)` |

1. Write the source. Start it with this header:

   ```
   <!-- title: EHOS runs beside the client's applications -->
   <!-- desc: One sentence about what the diagram shows. -->
   <!-- words: application, governance plane, operator -->
   <!-- technical: Kubernetes, eh_os_contract -->
   <!-- verbs: submits, grants -->
   <!-- parts: client = how-a-command-runs, kubernetes = - -->
   <svg viewBox="0 0 1000 680" xmlns="http://www.w3.org/2000/svg"> … </svg>
   ```

   `parts` gives, for each part, its concept in `docs/architecture/maturity.yml`, or `-` for a part
   that is no concept. Each `id` in the source starts with the id of the diagram and a dash
   (`command-arrow` in `command.svg`).
2. Give each element a class of the skin. The class sets the look; the source has no colour, no font
   and no `style`. The classes are in `@skin` of `lib/ehos/dev/diagrams.ex`. The most used:
   - parts: `n-focal` (the accent), `n-back`, `n-store`, `n-shared`, `n-ext`;
   - connectors: `arr` (solid), `uses` (dashed), `ring`, with `head` for an arrowhead;
   - text: `name`, `sub`, `lbl` (a connector's label), `zlabel` (a zone's label);
   - areas: `zone`, `mask`, `legend`, `key`;
   - maturity: `m-building`, `m-decided`, `m-planned`, `m-idea`, `m-open`.
3. Use only the elements and attributes that D-107 permits. The generator refuses all others by name:
   for example `<style>`, `<script>`, `<image>`, `<a>` and any colour.
4. Run `mix ehos.gen.diagrams`. It writes the outputs, and also the generated regions of the pages
   from `maturity.yml`. Commit the source, the outputs and the pages together.
5. Run `mix ehos.gen.diagrams --check`. Among others, it fails when one of these is true:
   - an output is not current with its source;
   - a label is not a word of the glossary and is not listed as technical;
   - the diagram is over the budget or breaks a connector rule;
   - no page links an output, or a page links an image that does not exist;
   - a page under `docs/` has a Mermaid block;
   - a generated region of a page was edited by hand.

   Its moduledoc in `lib/mix/tasks/ehos.gen.diagrams.ex` has the full list.
6. Look at the output in the light theme and in the dark theme.

When the architecture changes, `ehos-dev:architecture`, step 6, tells you which diagrams to update.

## In another repository

The generator is in eh-os only. It moves to ehos-tools in a later step.

1. Do not add a new Mermaid block. The Mermaid diagrams that exist stay until the generator is
   shared.
2. Write the source by the rules of this skill, with its header.
3. Show it to the user, and ask where it goes.

## Before you finish

- [ ] The diagram answers one question, and its type is the type for that question.
- [ ] 9 parts or fewer, 12 connectors or fewer, one accent.
- [ ] Connectors are orthogonal; each label has a mask; each connector has a number and a sentence in
      the key.
- [ ] Each label is a word of its owner's glossary, or listed as technical.
- [ ] The page text uses the same words as the picture.
- [ ] The title and the description are in the header; the description works as alternative text.
- [ ] In eh-os: `mix ehos.gen.diagrams --check` passes, and you looked at both themes.
