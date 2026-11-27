---
name: sample-data
description: Use whenever a contract of an application built on EHOS gains or changes a command, an event or a field, when someone asks for data to try a preview or an ephemeral environment on, and when the seed or its test fails — drafts the application's sample data from its contracts and has its seed record it through their commands, idempotently, by EHOS_SEED_PROFILE, never in production.
---

# Sample data for an ephemeral environment

EHOS runs the seed `ehos.yaml` names (`needs.database.seed`, eh-os D-98) in an ephemeral
environment only: after the migration, at every start of the workload, as the schema's owner, from
the application's image, with nothing of the application running. An EHOS application's data is
its contracts' events, and only a contract's command records one, so a seed that writes rows gives
a preview nothing to try. This skill has the seed record **sample facts through the contracts**,
and keeps them in step with every change to a contract.

The template writes the seed once, and then it is the application's: `<App>.Seed`
(`lib/<app>/seed.ex`), its test (`test/<app>/seed_test.exs`), the configuration they read, and the
call to `add/2` in `priv/repo/seeds.exs`. Its steps are what this skill writes. A project made
before ehos_app 0.25.0 has a seed that records no fact:
[`references/seed.md`](references/seed.md) says how to move it, and shows a step. One that had a
contract in `lib/<app>/contracts/` when the installer first ran has the template's seed without its
test: write the test, as step 5 there says, with its first step.

## When a contract changes

Every command a person may issue is either in the seed's `small` profile or named in the
domain's `not_seeded:`, with why (a command that only undoes another, one that needs an outside
system, one whose event holds a personal field). A command with `actor_is:` is the one exception:
the seed cannot issue it, and the list does not name it. So in the same change as the contract:

1. **A new command:** add a step that issues it, in a story that makes sense (a flag after the
   entry it flags). Or list it in the domain's `not_seeded:`, with why. Do not add the seed to its
   `by:`. A command whose event holds a personal field is always listed there, for now: see
   "Personal data". A domain with no seed actor gets one with the first step: see "The actor".
2. **A new or changed field:** give it a value in every step that builds the command. The steps are
   struct literals, so a removed or renamed field fails compilation; a new one does not, so look.
3. **A new invariant:** check that no step breaks it; the seed's test fails if one does.
4. **A changed step** keeps its key while its command's type stays: a new environment gets the new
   values, and one already seeded keeps the old fact until it is made again, since a replay
   compares the contract and the command's type, not its values. Never re-key a step to reach an
   environment already seeded: that issues the command again, onto a unit already there. A step
   whose command changes type gets a new key, which the old one would refuse as reused.

Then run the seed's test and `mix ehos_contract.check`.

## Drafting the data

- **Read the contracts first**: `mix ehos_contract.view --details` for the domain and every
  contract, `mix ehos_contract.glossary` for their words, and each contract's `scenario`s, which
  show what an accepted command looks like and what is refused.
- **Tell one story** in the domain's language, enough to try every screen: a handful of each unit,
  related to each other (the invoices of the companies the seed added), in the states their
  lifecycles allow, some of them past the first one. Not a scenario's `"c-1"`, not random values:
  someone shows a preview to the process owner.
- **Made up, always.** The seed ships in every image, production's included: no real person, no
  personal data that could be someone's, no credentials, no secrets, nothing copied from
  production. Use the outside systems' own test values where they have them (a test service's
  tax numbers), and say so in the step's comment.
- **An identity the caller gives** (an `identity` without `generated:`) is a fixed, made-up UUID in
  the step, so every start names the same unit. An identity the engine generates comes back in the
  receipt's `identity`, and a later step takes it from there.

## Personal data

A field declared `personal:` (`mix ehos_contract.view --details` marks it) is sealed with a data
key that the vault's master key wraps (`EhosContract.Vault`). EHOS gives the seed's container no
master key: no declared secret, and a `SECRET_KEY_BASE` that is no key at all (eh-os #576). So
in the seed a command whose event holds a personal field either fails, where the master key comes
from a secret, or worse, seals the field with a key derived from that placeholder, which the
serving application cannot unwrap: the fact is there, and its personal fields unreadable.

Until EHOS gives the seed the vault's master key
([ehos-tools#646](https://github.com/EmpoweredHouse/ehos-tools/issues/646)), such a command is
named in the domain's `not_seeded:`, with that reason. Leave out each step that needs its unit
too. Seed the units around it, whose data is no one's.

## The actor

The seed acts as the domain's seed actor, `:sample_data`. The domain declares it once, with the
commands that the seed must not issue and the reason for each:

```elixir
actor :sample_data, :seed, "Sample data",
  not_seeded: [approve_payment: "a payment needs the authority of a person"]
```

The seed dispatches with `EhosContract.Actor.seed(:sample_data)`. Build this actor in the seed
module only, never in a page, a controller, a context, a job or a task: the engine permits it in
production too, and the guard against production is in the seed. The engine then permits each
command, and each recorded event, that a `:human` actor of the domain may use, in every scope.
It refuses the seed with `:not_declared` in these cases, and writes nothing:

- `not_seeded:` names the command or the event.
- The command has `actor_is:`. The seed is no person, so the command is not seeded, and
  `not_seeded:` does not name it. Remove a step that issues one.
- No person may use the command.
- The call is a query.

No `by:` and no `recorded_by:` names the seed: `mix ehos_contract.check` refuses that
(`seed-actor-in-by`). A domain has one seed actor. A step that records an event from outside
uses `EhosContract.record/3`, which takes the same options as `dispatch/3`: give the seed's
`step/2`, which only dispatches, a clause for it. The seed's test reads commands only, so keep
those steps in step by hand. The template writes no domain without its example, so a project
made that way has no seed actor until you declare it in its domain with the first step.

The seed actor and its `not_seeded:` are a change to the domain, which its pages and graph show and
its process owner agrees to. No credential can carry the seed actor, so only the application's own
code acts as it. It acts in every environment, and no scope of a person's credential limits it. So
name a command in `not_seeded:`, with why, if its authority must hold even against the application's
own code (an approval, a payment, a grant). Never build a person's actor with
`EhosContract.Actor.credential/3` for the seed: that is a credential that EHOS never issued, written
into the log as someone.

An `EhosContract.Supplier` or an `EhosContract.Entities` of the application gets the seed actor,
`%Actor{kind: :seed}`, for a seeded command. Give it a clause of its own, which supplies or reads
only what the sample data needs. If no clause matches it, the call raises and the seed fails. A
clause that answers it as a `:system` actor reads the rows of every tenant for it.

An application whose seed is a `:system` actor that each `by:` names moves to the seed actor as
[`references/seed.md`](references/seed.md) says, in "Move the seed to the seed actor".

## The seed

- **`run/0`** is what EHOS runs, with nothing started: inside `Ecto.Migrator.with_repo/2` it
  starts an Oban that runs no queue, plugin or peer, with `Oban.Notifiers.Isolated`, and runs
  `priv/repo/seeds.exs`, which `mix ecto.setup` runs too. Dispatch inserts the job of an event's
  effect in the event's transaction, through `Oban.config/0`, which raises where no Oban runs.
  Oban stops before the repo does.
- **`add/2`**, which the script calls, loads the contracts (`EhosContract.Registry.load!/0`) and
  issues a profile's steps in order, with `EhosContract.dispatch/3` and the idempotency key
  `"sample:<step>"`, each step given the receipts of the ones before it. The key names the step,
  not the profile, so a step shared by two profiles is one fact. Its second argument is the
  seed's configuration, which a test gives in place of the application's.
- **It runs at every start**, so a second run adds nothing: an accepted key comes back as the first
  receipt, `duplicate: true`. A refusal that means the fact is already there (an invariant such as
  `:added_once`) is the seed done. Any other refusal raises, naming the step and the refusal's kind,
  never the command's values, so the workload's start fails rather than a preview being empty.
- **Only the contract's commands write.** Never insert into the engine's tables
  (`ehos_contract_*`) or a read model's: they are the engine's.
- **What it does not do:** read models delivered in the dispatch's transaction hold the data when
  the seed ends; policies, process managers, effects and timers catch up from the log once the
  application starts. A seeded event's effect then runs like any other, so an ephemeral
  environment's outside systems are their test services, never production's: check before
  seeding an event whose effect mails or pays.

## Profiles

EHOS gives the seed `EHOS_SEED_PROFILE`, the seed profile the environment's template names, when it
names one. `config/runtime.exs` reads it (code in `lib/` never reads the environment itself), and
the seed chooses by it:

| Profile | What it adds |
| --- | --- |
| `empty` | nothing |
| `small` | the default, also with no profile and on a development database: enough to try every screen and every command that the seed may issue |
| `demo` | optional: a longer story to show the process owner, `small`'s steps first |

An unknown profile raises, naming the ones the seed knows.

## Never in production

EHOS puts the seed into a deployment only in an ephemeral environment, and its operator refuses one
anywhere else: that is the boundary. The module still ships in production's image, where EHOS
names the environment in `EHOS_ENVIRONMENT` for every container, so the seed also guards against
an accident there:

- **`add/2`**, which writes, refuses where `EHOS_ENVIRONMENT` is one of the application's
  production environments: `run/0`, `seeds.exs` or a remote shell in a production container. With
  no `EHOS_ENVIRONMENT` it adds, as a development or test database needs, so never point a
  development command at production's database.
- **`run/0`** also refuses where `EHOS_ENVIRONMENT` names no environment, before it starts
  anything: EHOS always names the one it runs the seed in.
- **The list is the application's** (`:production_environments`), naming every production
  environment its installations have: `EHOS_ENVIRONMENT` is an environment's name, not its kind,
  and an installation may have several (eh-os D-57).

## Checking it

- The seed's test (`test/<app>/seed_test.exs`): `small` on an empty database answers each of its
  steps `:added`, each profile run a second time answers every step `:already`, every command a
  person may issue is seeded, named in the domain's `not_seeded:` or has `actor_is:`, and both
  refusals hold. The template
  writes it with an empty `small`: change its first test's answer with the first step.
- `mix ehos_contract.check` with no new finding, and `mix precommit`.
- Once by hand, cold, as EHOS runs it, against a development database whose schema is migrated:
  `EHOS_ENVIRONMENT=dev mix run --no-start -e "<App>.Seed.run()"`, twice.
