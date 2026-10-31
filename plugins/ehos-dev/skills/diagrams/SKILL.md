---
name: diagrams
description: Before you add or change a diagram in documentation about EHOS — an architecture overview, a flow, a sequence, the states of one thing — choose the one question it answers and its type, lay it out with the method of the `diagram-design` plugin within the budget, use the words of the glossary that owns each label, and say in the text what the picture says. Write the SVG source and generate it: with `mix ehos.gen.diagrams` in eh-os, and with `mix ehos_diagrams.gen`, from the `ehos_diagrams` package of ehos-tools, in another repository. Use with `ehos-dev:voice`, which says when a page needs a picture. Do not use for the contract graph that `eh_os_contract_graph` draws from data, nor for a screen of the console.
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
| `ehos_diagrams` | **Check the source and give it the look of EHOS**: the words, the budget, the colours and fonts of `ehos_design`, both themes | a package of ehos-tools ([T-21](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0021-eh-os-s-diagram-generator-is-shared-as-ehos-diagrams-a-package-here-that-takes-its-vocabulary-and-ehos-design-from-its-host.md)), which a repository pins by commit |

1. **Load `diagram-design:diagram-design` before you lay out a diagram.** Use its method for the
   layout. If it is not available, tell the user. Do not enable it yourself: it is third-party code,
   and `.claude/settings.json` is shared by every contributor.
2. **Use only its layout method and its references.** Do not run its onboarding, its profiles, its
   commands or its scripts (export, import, doctor). When it asks about a style guide, choose to keep
   the default: the look comes from the generator. Decline its offer to write a `.diagram-design` marker
   file in the project.
3. **Use the rules of this skill where they differ from diagram-design.** This skill gives the types,
   the budget, the words and the look of EHOS. Do not commit its HTML, PNG or styled SVG output.
   Leave out these extras of its types:
   - a second accent, such as the back-edge of a dependency graph or a second focal part;
   - a badge or a tag in the corner of a part that does not give maturity. Examples: the fan-in
     badge of a dependency graph, the replica badge and the type tag of a deployment;
   - an index tag such as `L3` or `07` on a layer. Number the layer with a `badge`, as rule 6 of
     "The rules of the picture" says;
   - a callout in a serif or italic font, such as the callouts of a nested diagram.
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
6. **Number the connectors.** If the type has no connectors, such as a layer stack or a nested
   diagram, number the parts. A number is a `badge` circle with its digit in `badget`. Under the
   figure, in the `key` area of the SVG, write the key: one
   short sentence for each number. The page gives the detail in a list with the same numbers, and
   does not copy the key.
7. **A dashed connector means optional or asynchronous.** It means nothing else. If two connectors
   differ in another way, the label and the key say how. Example: "compiles against" and "names".
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
   technical. `ehos-dev:voice`, "The words", gives the owners. A name that the page gives, such as
   the name of a layer, goes in `technical:` too.
2. **The label of a connector is a verb**: "submits", "grants", "records".
3. **Obey the list of words that are never alone**: "role binding", never "binding".
4. **The text of the page and the key use the same words as the picture.** The picture and the text
   say the same thing.
5. **Give each diagram a title and a description of one sentence.** The description is the
   alternative text: a reader who cannot see the picture gets the answer from it. It has 25 words or
   fewer, as `ehos-dev:voice` says for a description.

## Generating it

The shared generator is the `ehos_diagrams` package of ehos-tools. Each repository gives it its own
vocabulary: the words of its glossary, the words that are never alone and, in eh-os, the maturity
of each concept. The package README tells how a repository depends on it:
<https://github.com/EmpoweredHouse/ehos-tools/blob/main/packages/ehos_diagrams/README.md>.

| Repository | Source | Output | Command |
| --- | --- | --- | --- |
| eh-os | `docs/architecture/diagrams/<id>.svg` | `docs/architecture/img/<id>.svg` | `mix ehos.gen.diagrams` |
| another repository | `sources:` in `ehos_diagrams:` of its `mix.exs` | `out:` in the same place | `mix ehos_diagrams.gen` |

eh-os runs its own task, because the task also writes the generated regions of its pages from
`maturity.yml`. Until eh-os moves to the package (eh-os#1106), its task uses its own copy of the
generator.

In a repository other than eh-os that does not depend on `ehos_diagrams`, do not add a Mermaid
block. Write the source by the rules of this skill, show it to the user, and tell them that the
repository needs the package. Adding the dependency is a change of its own. "In another
repository", below, says what it needs. eh-os always follows
the steps below with its own task.

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

   `parts` gives, for each part, the concept that the part stands for, or `-` for a part that is no
   concept. In eh-os, the concepts are in `docs/architecture/maturity.yml`. In a repository without
   maturity, write `-` for each part. Each `id` in the source starts with the id of the diagram and
   a dash (`command-arrow` in `command.svg`).
2. Give each element a class of the skin. The class sets the look; the source has no colour, no font
   and no `style`. The classes are in `@skin` of `packages/ehos_diagrams/lib/ehos_diagrams.ex` in
   ehos-tools; in eh-os, until eh-os#1106, in `@skin` of its `lib/ehos/dev/diagrams.ex`. The most
   used:
   - parts: `n-focal` (the accent), `n-back`, `n-store`, `n-shared`, `n-ext`;
   - connectors: `arr` (solid), `uses` (dashed), `ring`, with `head` for an arrowhead;
   - text: `name`, `sub`, `lbl` (a connector's label), `zlabel` (a zone's label);
   - areas: `zone`, `mask`, `legend`, `key`;
   - maturity: `m-` and the badge, for each badge of the repository's vocabulary that has an
     outline. In eh-os: `m-building`, `m-decided`, `m-planned`, `m-idea`, `m-open`.
3. Use only the elements and attributes that D-107 permits. The generator refuses all others by name:
   for example `<style>`, `<script>`, `<image>`, `<a>` and any colour.
4. Run the command. It writes the outputs. In eh-os, it also writes the generated regions of the
   pages from `maturity.yml`. Commit the source, the outputs and the pages together.
5. Run the command with `--check`. Among others, it fails when one of these is true:
   - an output is not current with its source;
   - a label is not a word of the glossary and is not listed as technical;
   - the diagram is over the budget or breaks a connector rule;
   - no page links an output, or a page links an image that does not exist;
   - a page has a Mermaid block;
   - in eh-os, a generated region of a page was edited by hand.

   `EhosDiagrams` and `mix ehos_diagrams.gen` in the package have the full list; in eh-os, until
   eh-os#1106, `lib/mix/tasks/ehos.gen.diagrams.ex`.
6. Look at the output in the light theme and in the dark theme.

In eh-os, when the architecture changes, `ehos-dev:architecture`, step 6, tells you which diagrams
to update.

## In another repository

A repository other than eh-os meets these points when it adds `ehos_diagrams`. The package README
gives the dependency and the configuration.

- **A private ehos-tools needs a token in CI.** While ehos-tools is private, `mix deps.get` needs
  a token in the CI of the host. eh-os and eh-os-contract get one from the "ehos-tools CI" GitHub
  App, through `actions/create-github-app-token`. A maintainer adds its secrets to the host:
  `EHOS_CI_APP_ID` and `EHOS_CI_APP_PRIVATE_KEY`. A pull request from a fork gets no secrets, so
  its gate fails. A contributor who cannot read ehos-tools cannot run `mix deps.get`.
- **Keep the key of the App from people who must not have it.** The key can make a token for each
  repository that the App is installed on, eh-os-contract too. A person with write access to the
  host can change a workflow and read the key. Give write access only to people who can read each
  of those repositories. Do not turn on "Send secrets and variables to workflows from fork pull
  requests" (Settings, Actions, General). Do not run the gate on `pull_request_target` or
  `workflow_run`: these give the secrets to the code of a fork.
- **Give the token to one step.** Ask for `repositories: ehos-tools` and
  `permission-contents: read`. Give the token to the `mix deps.get` step alone. Put it in a Git
  `insteadOf` rule in the environment of that step: `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_0`,
  `GIT_CONFIG_VALUE_0`. Do not write it with `git config`. Check out with
  `persist-credentials: false`. Then the steps that compile and test the code do not have the
  token. The `mix.exs` of each dependency still runs in the `mix deps.get` step, and can read
  ehos-tools with the token.
- **Keep ehos-tools out of the caches of CI.** A pull request, also from a fork, can restore the
  caches of the base branch. In the paths of the caches, list the children of `deps` and `_build`,
  and exclude the packages of ehos-tools:

  ```yaml
  path: |
    deps/*
    !deps/ehos_*
    _build/*/lib/*
    !_build/*/lib/ehos_*
  ```

  Do not list `deps` or `_build` itself. `actions/cache` archives a listed directory whole. A `!`
  pattern removes a path only when the list holds that path. Also:
  - Exclude each other private package the same way, such as `eh_os_contract*` in eh-os.
  - Write the pair of patterns for each Mix project of the repository, such as `packages/*/deps/*`.
  - Do not cache a Dialyzer PLT where a pull request can restore it: it holds the types of
    `ehos_*` too.
  - If an earlier cache listed `deps` or `_build` whole, delete its entries (`gh cache delete`).
    A new key is not enough: a `restore-keys` prefix, or a step in a pull request, can still
    restore an old entry.
- **`ehos_design` brings Phoenix LiveView into `:dev` and `:test`.** The generator reads the tokens
  and the fonts in its `priv/`, but Mix compiles all of `ehos_design`. In a library, this adds
  Phoenix LiveView, premailex and floki to `:dev` and `:test`. A dependency of the host in `:test`
  alone, such as `phoenix_html`, can then need `only: [:dev, :test]`.
- **Leave out of `documents:` a page that still has a Mermaid block.** The `--check` fails on a
  Mermaid block in a page of `documents:`. Add each page when you convert its diagrams.
- **Give ExDoc the outputs.** If ExDoc publishes the pages, add the directory of the outputs to
  `assets:`, in the `docs/0` function of `mix.exs`. Example: `assets: %{"docs/img" => "img"}`.

## Before you finish

- [ ] The diagram answers one question, and its type is the type for that question.
- [ ] 9 parts or fewer, 12 connectors or fewer, one accent.
- [ ] Connectors are orthogonal; each label has a mask; each connector has a number and a sentence in
      the key. A type with no connectors numbers its parts.
- [ ] No extra of diagram-design that this skill leaves out.
- [ ] Each label is a word of its owner's glossary, or listed as technical.
- [ ] The page text uses the same words as the picture.
- [ ] The title and the description are in the header; the description works as alternative text,
      in 25 words or fewer.
- [ ] The command passes with `--check`, and you looked at both themes.
