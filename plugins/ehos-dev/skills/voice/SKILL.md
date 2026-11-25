---
name: voice
description: Before you write or change text that a person reads about EHOS — a documentation page, a README, a guide, a changelog line, or a string in the console or in `ehosctl` (a label, help text, a placeholder, a button, a confirmation, an empty state, a success or error message) — write it as technical documentation, not as a narrative. The sentence rules come from ASD-STE100 (Simplified Technical English), the words come from the glossary of the component that owns each word, and each page has one type and one question. Use for all text a user, a client or a newcomer reads. Do not use for code comments to the next maintainer, for decision records, or for how a repository builds its reference pages from code.
---

# Writing text that a person reads about EHOS

Text about EHOS is technical documentation. It is not a book, an essay or a story. The reader must
understand it once, without help, and do the correct thing.

This skill has four parts:

- **The words** come from the glossary of the component that owns them. One word has one meaning.
- **The sentences** follow the writing rules of ASD-STE100, Simplified Technical English. The rules
  below are a summary in our words. The full specification is free from ASD on request
  (<https://www.asd-ste100.org>). We do not use the ASD dictionary: our glossaries are the dictionary.
- **The pictures** show what sentences show badly. The `ehos-dev:diagrams` skill tells how to draw
  them.
- **The pages** have one type and answer one question.

This skill applies to English text that EHOS and its libraries show. A client's labels in an
application follow the client.

## The readers

| Reader | Knows | Needs |
| --- | --- | --- |
| A person with a business problem: a process owner, an operator, a manager | the business, not the technology, and not EHOS | what EHOS does for this problem, what an action does, what follows from it |
| A technical person: a developer, an architect, a partner | the technology, not EHOS | the mechanism, the limits, an example that runs |

Most readers do not know EHOS. Many readers do not have English as their first language.

1. Write the first sentence of a page, a section or a help text for the reader who knows least.
2. Put the technical detail after it, or on its own page.
3. Do not write a separate text for each reader.

## The words

Each term has one owner: the component that defines the thing. The glossary of the owner gives the
meaning. No other glossary defines the term again.

| Component | Owns the words for | Glossary |
| --- | --- | --- |
| eh-os | the platform: installation, environment, ephemeral environment, deployment, promotion, role binding, platform capability, the console | [`docs/architecture/glossary.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md) |
| `ehos_contract`, the engine (ehos_contract) | the contract language: domain, context, contract, unit, command, event, reaction, read model, query, process, process module, promise, capability, run, stage, verdict | [`docs/glossary.md`](https://github.com/EmpoweredHouse/ehos_contract/blob/main/packages/ehos_contract/docs/glossary.md) |
| `ehos_design` (ehos-tools) | the design system: token, component | none yet; its `README.md` |
| `ehosctl`, `ehos_app` (ehos-tools), `ehos_contract_auth` (ehos_contract) | no words of their own: they connect to EHOS and use the words of eh-os | — |

1. **Use the word of the owner for each thing.** Do not use a synonym: the reader thinks that it is a
   different thing.
2. **Words go in the direction of the dependencies.** A component uses its own words and the words of
   the components that it depends on. eh-os uses the words of `ehos_contract`. The engine
   `ehos_contract` and `ehos_design` never use the words of eh-os, because they stand alone.
   The name "EHOS" is a word of eh-os. The pages of `ehos_contract` and `ehos_design` do not use
   it. One exception: the first paragraph of their Overview can say that EHOS uses them.
3. **Obey the list of words that are never alone** in the eh-os glossary. Write "role binding", never
   "binding"; write "environment template" or "application template", never "template".
4. **In the first paragraph, link the glossary of each owner whose words the page uses, one time.**
   That link covers each word of that glossary on the page. If the glossary does not have a word,
   define it in the text, in one sentence. A name that the page gives is such a word. You can also
   define a glossary word in the text when the reader needs it for the next step. Do not link from
   `ehos_contract` or `ehos_design` to eh-os, also not for "EHOS" in their Overview.
5. **For a new term, add it to the glossary of its owner in the same pull request.** If the owner is
   another repository, open a pull request there first.
6. **If a glossary defines a term that another component owns, stop and tell the user.** The owner
   decides the term, and the other glossary links to it. Example: `ehos_contract` owns "Command".
   The row for "Command" in the eh-os glossary links to the glossary of `ehos_contract`. The row
   says only what EHOS adds.
7. **Give one meaning to each common word.** Do not use "run" for "a run of a process" and for "start
   a program" on one page.
8. **Use the simple word**: "use", not "utilize"; "start", not "initiate"; "make sure", not "ensure";
   "about", not "approximately"; "help", not "facilitate".
9. **Do not put internal codes in text for a user.** No decision numbers (`D-105`, `T-16`), test
   numbers (`FM-23`), stage or step numbers, or issue links in the body of a page. No rule or layer
   codes (`D11`, `L3`, `§6`). If the reason is
   useful to a technical reader, put links to the decision records in one "Background" section at the
   end of the page. You can put a refusal code after its sentence, where a program matches on it.
   Two exceptions: the architecture pages of eh-os cite their records as `ehos-dev:architecture`
   says, and a region that a tool generates stays as the tool writes it.
10. **Do not use "simply", "just", "easy", "obviously"**, idioms, metaphors, humour or emoji.

## The sentences (from ASD-STE100)

1. **One instruction in one sentence.** Write two instructions in one sentence only when the reader
   does them at the same time.
2. **Write an instruction in the imperative**: "Select **Promote**", not "You should select" or "The
   user selects".
3. **An instruction has 20 words or fewer. A description has 25 words or fewer.**
4. **One fact in one descriptive sentence.**
5. **Write the condition first**: "If the deployment fails, read the logs of the environment."
6. **Use the active voice, and name who does the action**: the person, EHOS, the application, the
   pipeline. Not "The promotion is approved", but "The process owner approves the promotion".
7. **Use simple tenses**: the present, the simple past, the future.
8. **Do not use more than three nouns in a cluster.** Write "the image of the candidate", not "the
   candidate deployment image digest".
9. **Do not use more than one possessive in a phrase.** Not "production's deployment's image", but
   "the image of the deployment in production".
10. **Do not leave out "the", "a", "that"**, as notes and headlines do.
11. **Do not use "-ing" forms as nouns or after a preposition**: "before you deploy", not "before
    deploying".
12. **A paragraph has one topic.** The first sentence gives the topic. A paragraph has six sentences or
    fewer.
13. **Use a vertical list** for steps, and for three or more items.
14. **Write numbers as digits, with the unit**: "2 minutes", "10 GB". Write a date as "30 October 2026".

## What to say

1. **Say what a thing is for before how it works.** The first sentence gives the problem that the thing
   solves, as a fact, not as a slogan.
2. **Say the consequence of each action**: what changes, who sees it, if it can be undone, what it
   costs.
3. **Say the limits**: what EHOS does not do or does not check, and what the reader must do.
4. **After a step, give the result** that the reader sees when the step is correct.
5. **An error message gives three things**: what occurred, why, what to do now. Use the kinds and the
   sentences of the refusals page:
   <https://github.com/EmpoweredHouse/eh-os/blob/main/docs/refusals.md>.
6. **Put a warning before the step that it applies to.** Start the warning with a command, then give
   the reason: "Copy the token now. EHOS does not show it again."
7. **Write a heading as the reader's task or question**: "Promote a version to production", "What
   occurs when a deployment fails?". Not "Deployment failure semantics".
8. **Give a warning box a title that is the fact**: "An approval does not check the image". Not
   "Note" or "Warning".
9. **Do not tell history.** The text says how the product is now. How a decision was made goes to the
   decision record.
10. **If you do not know a consequence, read the code or ask.** Do not write a consequence that you
    did not verify.
11. **Do not make a limit into an absolute.** Write "never", "nothing", "only" or "all" only when
    the code makes it true. Not "The check refuses nothing", but "The check fails when it finds an
    error".

## The pictures

A diagram explains a difficult thing faster than paragraphs. Use one when the text describes:

- parts and the connections between them;
- an order of steps between two or more actors;
- the states of one thing;
- a flow of information or of a decision.

If a Concept page or an Overview page describes one of these without a diagram, add one.

1. **One diagram answers one question.** Write the question, or the answer, as its title.
2. **The picture and the text say the same thing, with the same words.** The picture has the key:
   one short sentence for each number. The text of the page follows the same numbers and gives the
   detail. It does not copy the sentences of the key.
3. **Each diagram has a description of one sentence, with 25 words or fewer.** It is the
   alternative text.
4. **Do not draw the same diagram two times.** Link to the page that has it.
5. **Do not draw a diagram to decorate a page.**

Before you draw, load `ehos-dev:diagrams`. It gives the twelve types, the budget, the layout rules,
and how to generate the picture.

## The pages

Each page has one type and answers one question. Do not mix two types on one page: link to the other
page.

| Type | Question | Contents |
| --- | --- | --- |
| Overview | What is this, and which problem does it solve? | the problem, what EHOS does, for whom, links to the next pages |
| Getting started | How do I see it work one time? | prerequisites, numbered steps, the result of each step, next steps |
| How-to | How do I do this task? | the task or the goal as the title, prerequisites, steps, the result, what can go wrong |
| Concept | What is this, and how does it work? | the purpose, the parts, one example, the limits |
| Reference | What does this accept and give? | complete and exact; generated from the code when possible; no story |
| Troubleshooting | Why did I get this message? | the exact message as the heading, the cause, the fix |

A How-to can hold several tasks for one goal. Example: a guide to describe a business has a task
for the domain, one for each contract, and one for the process module. Give each task a section.
Write the heading of each section in the imperative. The tasks share the prerequisites at the top
of the page.

A cell of a Reference table follows the sentence rules: one fact in a sentence, 25 words or fewer.
Do not chain clauses in a cell with semicolons. If a cell needs more, write a section under the
table and link it from the cell. A list of names or values in a cell, such as `:string, :integer`,
is not a sentence.

Each page:

1. Starts with one paragraph that says what the page covers and for whom.
2. Gives the prerequisites before the first step.
3. Ends with "Next steps": the pages that the reader needs after this one.

The documentation has one overview page for all of EHOS. It gives each area two or three sentences
and a link.

## The console and `ehosctl`

The interface tells the user what a control does and what it changes. The documentation tells why
and how.

| Element | Rule | Not | But |
| --- | --- | --- | --- |
| Page title | the thing or the task, in glossary words | "Bindings" | "Role bindings" |
| Label | the name of the field; no format, no exception | "Limits, as a LimitRange's limits in JSON (empty: the installation's)" | "Resource limits" |
| Help text | the purpose, what occurs if the field is empty, then the format | — | "If empty, the default of the installation applies. Format: the limits of a Kubernetes LimitRange, as JSON." |
| Placeholder | an example value, not an instruction | "Enter the repository" | "acme/billing" |
| Button | a verb and its object | "OK", "Submit" | "Remove role binding" |
| Confirmation | the action, its consequence, if it can be undone; the button has the same verb | "Remove admin from jan@acme.com?" | "Remove the role binding admin for jan@acme.com? Jan loses the capabilities of this role here." — **Remove role binding** / **Cancel** |
| Empty state | what this list shows, and how an item gets here | "None asked for yet." | "No promotions. A promotion shows here when a person asks to move a candidate to production." |
| Success message | what occurred, with the name of the thing | "Refused." | "You refused the promotion of billing 1.4." |
| Error message | what occurred, why, what to do now | "Production's deployment would be refused; ask again to see why." | "Production does not accept this candidate. Ask again to see the reasons." |

A good example from the refusals page: "Your sign-in has expired. Run `ehosctl login`."

## Before and after

The start of the promotions page of eh-os:

> **Before:** "A version reaches production by **promotion** (D-105). A candidate is a deployment
> that is active in an ephemeral environment of its application, where people can try it. […] The
> approval decides production's deployment, from the candidate's image and manifest, against
> production's own names, bindings and secrets (FM-23, FM-26, FM-27)."
>
> **After:**
>
> A promotion moves one version of an application to production. The
> [glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
> defines the words of this page.
>
> 1. Deploy the version to an ephemeral environment. An ephemeral environment is a temporary copy
>    of the application where people can try the version. This deployment is the *candidate*.
> 2. Ask for a promotion of the candidate to one production environment.
> 3. The process owner of the application approves or refuses the promotion.
>
> If the process owner approves, EHOS deploys the image and the manifest of the candidate to
> production. EHOS does not copy the names, the authority or the secrets of the ephemeral
> environment: it checks and resolves them again for production.

The source also says "bindings", alone. The glossary never shows that word alone, and the source
does not say which kind it means. Do not guess: ask the owner of the page, as rule 10 of "What to
say" tells you.

The start of the contract guide of `ehos_contract`:

> **Before:** "A business process is written down twice. First as a **domain**: the words its people
> use, the contexts it is split into, who acts in it and which systems it depends on. Then, once per
> process, as a **contract** […]"
>
> **After:**
>
> You describe a business in up to three kinds of Elixir module. The
> [glossary](https://github.com/EmpoweredHouse/ehos_contract/blob/main/packages/ehos_contract/docs/glossary.md)
> defines each word in italics.
>
> - A *domain* contains the words of the business, its contexts, its actors and the external systems
>   that it uses.
> - A *contract* belongs to one context. It contains the units that decide, their commands and
>   events, the reactions to the events, and the queries.
> - A *process module* describes one kind of run of the business, across one or more contracts,
>   and the promises of that run. A business with no run, such as a register of rooms, needs none.
>
> The engine reads these modules. At compile time, it refuses a model that contradicts itself. At
> run time, it records the events and compares them with the promises of each process.

The "before" text describes one contract for each process, with its promises. The rest of that
page says that a process module holds the promises. A rewrite is a good moment to find such a
contradiction: check the model against the code before you write the new text.

## Before you publish

Check each item. To count, run `measure-prose.exs`, beside this file:
`elixir <the directory of this skill>/measure-prose.exs --long <page>…`. It lists the long
sentences and the sentences that a code carries. Its counts are estimates: read each hit. The other
items need you to read the page.

- [ ] Each instruction has 20 words or fewer; each description has 25 words or fewer.
- [ ] Each sentence has one instruction or one fact.
- [ ] No passive sentence hides who does the action.
- [ ] No cluster of more than three nouns; no chain of possessives.
- [ ] Each term is the word of its owner. The first paragraph links the glossary of each owner.
- [ ] No internal codes in the body:
      `grep -nE '\b[A-Z]{1,2}-?[0-9]{1,3}\b|§|#[0-9]+|[Ss](tage|tep) [0-9]'`, then read each hit: a
      step of a how-to is not a code.
- [ ] No "never", "nothing", "only" or "all" that the code does not make true.
- [ ] No "simply", "just", "easy", "obviously"; no idioms; no emoji.
- [ ] Each action gives its consequence; each error gives what, why and what to do.
- [ ] A part, an order, a state or a flow that is difficult to follow has a diagram.
- [ ] The page has one type, starts with its scope, and ends with "Next steps".
- [ ] The text tells how the product is now, not how it was made.
