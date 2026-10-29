# Deploying

```sh
ehosctl deploy ledger --env staging \
  --image ghcr.io/example/ledger@sha256:<digest> --manifest manifest.json
```

`deploy` does what the console's Deploy does: one decision that puts the manifest in force in the
environment and gives the cluster the image
([eh-os `docs/manifest.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/manifest.md#deploying-with-one)).
It needs `ehos.application.deploy` there, and `ehos.application.register` too when the manifest
changes the application's authority.

- **The manifest** is sent as its file holds it, byte for byte, since EHOS keeps and digests what
  it was sent; `--manifest -` reads it from stdin. It must be the manifest of the application the
  command names, or nothing is sent.
- **The image** is named by digest; a tag is refused.
- **Where it came from** may be stated with `--commit`, 40 or 64 lowercase hexadecimal
  characters, and `--ref`, such as `refs/heads/main`. They are sent only when you give them, never
  read from a checkout, whose commit has no tie to the image deployed; their form is checked as
  EHOS checks it, their truth by no one, and EHOS shows them beside the digest as stated by you
  ([eh-os D-129](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0129-a-deployment-shows-beside-its-digest-the-github-run-its-credential-was-exchanged-for-or-what-its-deployer-states.md)).
  A deployment from a GitHub Actions job is named by its run instead, as GitHub's token says it,
  and what the job states is not taken.
- **The answer** comes once the cluster has the deployment's objects, while it is `activating`:
  the deployment's id, the image, where it came from when EHOS names it ("from GitHub's token: …"
  or "stated by …: …", told apart by the `kind` EHOS sets) and both of the manifest's digests.
  `ehosctl apps show` says the same of each environment's deployment in force. A deployment the
  cluster did not take exits 5 with its failure; one a later deployment overtook exits 1. Both
  name the deployment.
- **Then it waits** until the deployment is active (eh-os#413), reading the application's
  deployments in the environment, as the console's application page shows them, after two
  seconds and then further apart, up to every ten, and printing each state it moves to:

  ```text
  Waiting until it is active, for at most 10 minutes:
    activating
    active
  Deployment 5f0c… is active in staging, at https://ledger.staging.example.com.
  ```

  It exits 0 once EHOS says the deployment is `active`, and says so when another decided after it
  is in force by then; 1 when it `failed`, with its failure's words, or EHOS says it was
  `superseded`; and 5 when ten minutes pass first, saying the state it is still in and that
  `ehosctl apps show <app>` says it later, or when so many deployments were decided after it that
  EHOS no longer lists it among the newest. A read EHOS did not answer, or answered that it could
  not now, is tried again until then. Reading the deployments needs `ehos.application.deploy` or
  `ehos.application.register` there; a refusal of it ends the wait at once, since EHOS records
  each one, with its exit code, as does any other error, each saying that the deployment, by its
  id, was decided. Against an EHOS older than that route, it says it cannot follow the deployment
  there, and exits 0. `--json` prints one document at the end: EHOS's answer, kept to the fields
  `ehosctl` reads, with the deployment's last `state` and `failure`, the `outcome` (`active`,
  `failed`, `superseded`, `waiting`, `displaced`, or `not_followed` on an older EHOS) and the
  `addresses`.
- **`--no-wait`** returns once the deployment is decided, as `deploy` did before it waited, with
  the same words and `--json`; whether it became active is then on the application's page in the
  console.
- **A refusal** is the deploy page's sentence: a database the environment keeps that the manifest
  drops, for one, is `database_kept`, and exits 1.

```sh
ehosctl deploy ledger --env staging --manifest manifest.json --preview
```

`--preview` deploys nothing: it prints what the deployment would do, as the console's deploy page
shows it before it is confirmed. That is both of the manifest's digests and the version in force;
that EHOS does not know the application yet, when the deployment would register it; what its
authority adds and takes away, in `apps review`'s words, or that it changes no one's; that it
also needs `ehos.application.register`, when you hold it; what each need would be bound to, or
why it cannot be; what it changes in sign-in and in reading the company's people; the mail it
asks to send through EHOS, to people in EHOS's directory only or to any address and with replies to
which domains, against what the deployment in force there asks (eh-os D-140); and every reason the
deployment would be refused.

- **Mail** is sent as far as the mail agreement for the environment allows, once someone who holds
  `ehos.mail.manage` gives it, on the console's Installation page or with `ehosctl mail agree`
  ("Agreements"). `--json` keeps EHOS's `mail` and `mail_in_force`, each
  `{"level", "reply_domains"}` or null; an EHOS older than mail gives neither, and both are null.
- **A host that is the installation's mail server**, among those the manifest names under
  `needs.egress`, is said: where the relay admits the server by its address, the application can
  send through it as anyone in the company's domain, around its mail agreement (eh-os D-141).
  Nothing is refused for it; approve it only if that is meant. Only a relay that requires a user,
  and no longer admits the server by its address, closes it. `--json` keeps each `egress` entry as
  `{"host", "port", "mail_relay"}`; an EHOS older than the mark did not check, and its entries
  carry no `mail_relay`.

- **The exit code** is 0 when the deployment would be taken, and 1 when it would be refused, with
  the preview and its reasons printed all the same; `--json` prints the preview, its `refusals`
  empty or not.
- **No image** is taken: EHOS previews the manifest alone and checks the image when it is
  deployed, so `--image` with `--preview` is refused rather than left unchecked. Without
  `--preview`, `--image` is needed.
- **It needs** `ehos.application.deploy` there, as deploying does; a refusal of the preview is
  said as `deploy` says it.
