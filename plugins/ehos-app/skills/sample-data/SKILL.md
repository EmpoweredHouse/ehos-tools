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

The application owns its seed, `<App>.Seed` (`lib/<app>/seed.ex`); the template wrote it once.
[`references/seed.md`](references/seed.md) holds a model of it and its test: read it before you
write either.

## When a contract changes

Every command a person may issue is either in the seed's `small` profile or named in its
`@not_seeded` with why (a command that only undoes another, one that needs an outside system). So
in the same change as the contract:

1. **A new command:** add a step that issues it, in a story that makes sense (a flag after the
   entry it flags), and add `:sample_data` to its `by:`. Or list it in `@not_seeded`, with why.
2. **A new or changed field:** give it a value in every step that builds the command. The steps are
   struct literals, so a removed or renamed field fails compilation; a new one does not, so look.
3. **A new invariant:** check that no step breaks it; the seed's test fails if one does.
4. **A changed step:** give it a new key (`"entry-rent-2"`), never new values under its old key: a
   replay compares the contract and the command's type, not its values, so an environment already
   seeded keeps the old fact and says nothing.

Then run the seed's test and `mix eh_os_contract.check`.

## Drafting the data

- **Read the contracts first**: `mix eh_os_contract.view --details` for the domain and every
  contract, `mix eh_os_contract.glossary` for their words, and each contract's `scenario`s, which
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
  the step, so every start names the same unit. One the engine generates comes back in the
  receipt's `identity`, and a later step takes it from there.

## The actor

The seed acts as the domain's `:system` actor `:sample_data`:

```elixir
actor :sample_data, :system, "Sample data"
```

and each command it issues names it in `by:`, beside the person who issues it in production:
`by: [:clerk, :sample_data]`. An event the contract records from an outside system
(`recorded_by:`) is recorded as that system's actor, with `EhOsContract.record/3`.

This is a change to the contract, which its pages show and its process owner agrees to. No
credential can carry a `:system` actor, so only the application's own code acts as it. Never build
a person's actor with `EhOsContract.Actor.credential/3` for the seed: that is a credential EHOS
never issued, written into the log as someone.

## The seed

- **`run/0`** is what EHOS runs, with nothing started: inside `Ecto.Migrator.with_repo/2` it loads
  the contracts (`EhOsContract.Registry.load!/0`) and starts an Oban that runs no queue, plugin or
  peer, with `Oban.Notifiers.Isolated`. Dispatch inserts the job of an event's effect in the
  event's transaction, through `Oban.config/0`, which raises where no Oban runs: a seed with the
  repo alone fails the start the day an effect is declared on a seeded event. Oban stops before the
  repo does.
- **`add/1`** issues a profile's steps in order, with `EhOsContract.dispatch/3` and the idempotency
  key `"sample:<step>"`, each step given the receipts of the ones before it. The key names the
  step, not the profile, so a step two profiles share is one fact.
  `priv/repo/seeds.exs` calls it for a development database, where the application runs.
- **It runs at every start**, so a second run adds nothing: an accepted key comes back as the first
  receipt, `duplicate: true`. A refusal that means the fact is already there (an invariant such as
  `:added_once`) is the seed done. Any other refusal raises, naming the step and the refusal's kind,
  never the command's values, so the workload's start fails rather than a preview being empty.
- **Only the contract's commands write.** Never insert into the engine's tables
  (`eh_os_contract_*`) or a read model's: they are the engine's.
- **What it does not do:** read models delivered in the dispatch's transaction hold the data when
  the seed ends; policies, process managers, effects and timers catch up from the log once the
  application starts.

## Profiles

EHOS gives the seed `EHOS_SEED_PROFILE`, the seed profile the environment's template names, when it
names one. `config/runtime.exs` reads it (code in `lib/` never reads the environment itself), and
the seed chooses by it:

| Profile | What it adds |
| --- | --- |
| `empty` | nothing |
| `small` | the default, also with no profile and on a development database: enough to try every screen and every command not in `@not_seeded` |
| `demo` | optional: a longer story to show the process owner, `small`'s steps first |

An unknown profile raises, naming the ones the seed knows.

## Never in production

EHOS puts the seed into a deployment only in an ephemeral environment, and its operator refuses one
anywhere else. The seed still refuses where `EHOS_ENVIRONMENT` is one of the application's
production environments, which its configuration lists: the module ships in production's image,
and anyone with the cluster's access could `eval` it. `EHOS_ENVIRONMENT` is an environment's name,
not its kind, and an installation may have several production environments (eh-os D-57), so the
list is the application's, not a literal `"production"`.

## Checking it

- The seed's test (`test/<app>/seed_test.exs`): each profile run twice in the sandbox, every step
  `:added` the first time and `:already` the second, and every command a person may issue either
  seeded or in `@not_seeded`.
- `mix eh_os_contract.check` with no new finding, and `mix precommit`.
- Once by hand, cold, as EHOS runs it, against a development database whose schema is migrated:
  `mix run --no-start -e "<App>.Seed.run()"`, twice.
