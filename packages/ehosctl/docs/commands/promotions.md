# Promotions

A version of an application gets to production only by a promotion. This page is for a developer
and a process owner. It tells how to ask for a promotion, read its review, and approve or
refuse it. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page, and
[`docs/promotions-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/promotions-api.md)
of eh-os describes the API that these commands use.

```sh
ehosctl promotions ledger
ehosctl promotions --waiting
ehosctl promote ledger --candidate 1f0c2b3a-0000-4000-8000-000000000001 --env production
ehosctl promotions show 4c7a6b5e-0000-4000-8000-000000000004
ehosctl approve 4c7a6b5e-0000-4000-8000-000000000004
ehosctl refuse 4c7a6b5e-0000-4000-8000-000000000004 --reason "Wait for the audit"
ehosctl promote --withdraw 4c7a6b5e-0000-4000-8000-000000000004
```

A promotion has these steps:

1. A person or a pipeline deploys the version to an ephemeral environment of the application.
2. When that deployment is active, it is a *candidate*. People try it at its address.
3. A person who can deploy to production asks for a promotion of the candidate.
4. A person who can approve promotions there approves or refuses it. This person is the process
   owner of the application, or an administrator.
5. If the person approves, EHOS deploys the image and the manifest of the candidate to production.

The console shows the same promotions on the page of the application, and on its Approvals page.

## Prerequisites

- Sign in with `ehosctl login`.
- To read the promotions of an application, hold `ehos.application.deploy`,
  `ehos.application.register` or `ehos.release.approve` in the application.
- To ask for a promotion, hold `ehos.application.deploy` for the application in that production
  environment.
- To approve or refuse a promotion, hold `ehos.release.approve` in that production environment. To
  approve a promotion that changes the authority of the application, also hold
  `ehos.application.register` there.

## List the candidates and promotions of an application

`ehosctl promotions <app>` shows:

- for each production environment, the step that the newest attempt is at, as in the list above;
- if four eyes is on;
- the candidates, each with its id, its environment, its image, who deployed it, and its address;
- where each candidate came from, if EHOS knows it;
- the 50 newest promotions, each with its id, its state, who asked for it and who decided it.

If the person who decided a promotion also deployed the candidate or asked for the promotion, the
list marks the promotion `self-approved`. This occurs only when four eyes is off.

EHOS shows the step of a production environment only to a person who can deploy, register or
approve there. For anyone else, the command says so.

## List the promotions that wait for you

`ehosctl promotions --waiting` lists the promotions that you can approve, in each application,
the oldest first. If four eyes is on, the list does not show a promotion that you asked for or
whose candidate you deployed.

## Ask for a promotion

1. Find the id of the candidate with `ehosctl promotions <app>`.
2. Run `ehosctl promote <app> --candidate <id> --env <production>`.

The command prints the id of the promotion and its state, `requested`. Production does not change
until a person approves the promotion.

One request waits for each application in a production environment:

- If you ask again for the same candidate, EHOS gives back the request that waits.
- If you asked before for another candidate, your new request withdraws your older one.
- If another person's request waits, EHOS refuses yours as `already_requested`, exit 1. The
  command prints the id of that request. Read it with `ehosctl promotions show <id>`. To withdraw
  it and ask for yours, run the command again with `--replace <id>`. EHOS records the withdrawal as
  yours.

EHOS refuses the request as `would_be_refused`, exit 1, if production does not accept the
candidate now. The message gives each reason. A reason that starts with `publishes:` names a name
that another application in production reads and that the candidate stops publishing. To break
those applications on purpose, run the command again with `--break <reason>`. Only a person who
can approve the promotions of each of those applications can approve yours.

## Withdraw a promotion

Run `ehosctl promote --withdraw <id>`. You can withdraw a promotion that you asked for. With
`ehos.application.deploy` in that production environment, you can withdraw any promotion that
waits there. Production does not change.

EHOS also withdraws a promotion when its candidate stops being active. For example, a later
deployment replaces the candidate, or a person removes its ephemeral environment.

## Read the review of a promotion

Read the review before you approve or refuse a promotion. `ehosctl promotions show <id>` shows
the same parts as the review in the console, in this order:

1. What the approval promotes: the image of the candidate, from its environment to production.
2. What you must know before you decide. For example, production changed after the request, or
   production does not accept the candidate now. A warning is a line that starts with `!`,
   yellow on a terminal, with the explanation under it. There are three warnings:
   - EHOS did not check what the candidate does.
   - EHOS could not check some points about the applications that read from it.
   - The candidate can reach a mail server of the installation.

   For a utility service, this part says what you confirm for a program with no contract. While
   the promotion waits, it lists the applications that ask to call the service in that production
   environment or have a service agreement for it, each with its service agreement, as
   `ehosctl services list` shows them. EHOS gives this list only to a person who can deploy,
   register or approve in that production environment. For a utility service that adds
   a host, this part also lists the applications that the approval agrees for, and the hosts
   that each application then reaches. For an application that starts to call a utility service,
   it lists the hosts of that service.
3. The record of the promotion: its state, the address of the candidate, its image, its manifest,
   and where it came from, each value after its label, aligned.
4. What it changes in production: the version in force, a link to the changes of the code on
   GitHub, and the changes of authority. For a utility service, which has no capability or role,
   it lists the hosts outside the installation that it adds or removes.

EHOS shows the part about production only to a person who can deploy, register or approve in that
production environment. For anyone else, the review says so.

### An approval does not check the image

EHOS did not check that the image of the candidate does what its manifest says. A person tried
the candidate in its ephemeral environment. If you approve, you confirm that the candidate does
what it must do.

## Approve or refuse a promotion

1. Run `ehosctl approve <id>`. The command prints the review of the promotion, then an empty
   line, then the question.
2. Read the review.
3. Answer `y` to approve the promotion. Any other answer approves nothing.

The question comes after the whole review, on a line of its own:

```text
In production:
  Version in force now   sha256:c3c3c3c3c3c3…
  Code changes           https://github.com/example/ledger/compare/fedcba987654...0123456789ab

Approve promotion 4c7a6b5e-…? EHOS then deploys the candidate to production. [y/N]
```

When the command asks, it prints the review on standard error, with the question. When it does
not ask, as with `--yes` or in a job, it prints the review on standard output.

When you approve, EHOS deploys the candidate to production. The command then waits until the
deployment is active, for at most 10 minutes, and prints each state. If the deployment fails, the
command prints the failure and exits with code 1. To return when EHOS decides the deployment, give
`--no-wait`.

If the review says that you cannot approve the promotion, the command does not ask and sends
nothing. For example, production changed after the request, or four eyes is on and you deployed
the candidate. The review says what to do.

To approve without the question, as in a script, give `--yes`. Where nobody can answer, such as in
a job, the command approves nothing without `--yes`.

To refuse a promotion, run `ehosctl refuse <id> --reason <text>`. The reason has 1 to 1024
characters. The person who asked for the promotion reads it. Production does not change.

## JSON and exit codes

With `--json`, each command writes one JSON document with the fields that `ehosctl` reads.
`promotions <app>` writes `four_eyes`, `candidates`, `production`, `way` and `promotions`.
`promotions --waiting` writes `promotions`. `promotions show` writes `review`, with the keys that
EHOS gave. `promote` and `refuse` write `promotion`.

`approve --json` needs `--yes`. It writes `review`, the approved `promotion`, the id of the
`deployment` in production, and its last `state` and `failure`. When it waits, it also writes the
`outcome` and the `addresses`, as `deploy --json` does.

A process owner who holds only `ehos.release.approve` cannot read the deployments in production.
For this person, `approve` does not wait. It says so, and exits 0, because the approval is made.
With `--json`, the `outcome` is `not_followed`.

Some refusals have more fields beside `code`. `already_requested` has `waiting`, the id of the
request that waits. `would_be_refused` has `refusals`, the list of reasons.

If EHOS refuses the request, the command exits with the code of the refusal. For an id that EHOS
does not know, EHOS answers `not_found`, exit 1. For a person who cannot read the promotions, EHOS
answers `forbidden`, exit 3. [Output and exit codes](output.md) lists the codes.

## Next steps

- [Deploying](deploy.md): deploy a candidate to an ephemeral environment.
- [Builds](builds.md): deploy a build that the pipeline of the application registered.

## Background

- [eh-os D-105](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0105-production-is-reached-only-by-promoting-a-candidate-and-a-promotion-is-a-record-of-its-own-approved-by-the-application-s-process-owner.md):
  production gets a version only by a promotion.
- [eh-os D-132](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0132-a-promotion-is-refused-when-it-would-stop-publishing-a-name-another-application-in-that-environment-subscribes-to-read-from-the-graph-documents-its-deployments-carry.md):
  a promotion that stops publishing a name that another application reads.
- [eh-os D-128](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0128-four-eyes-on-promotions-is-off-unless-an-installation-turns-it-on-and-an-installation-that-had-it-keeps-it.md):
  four eyes on promotions.
- [eh-os D-146](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0146-a-build-is-a-record-of-its-own-registered-by-ci-with-the-commit-it-came-from-a-deployment-names-a-build-and-a-promotion-s-review-links-to-what-changed.md):
  the review links to what changed in the code.
- [eh-os D-175](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0175-a-utility-service-is-an-application-with-no-contract-deployed-to-environments-as-any-other-and-another-application-reaches-it-only-once-the-service-s-side-agrees.md):
  an approval of a utility service that adds a host also agrees for the applications that call it.
