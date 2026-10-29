# Secrets

```sh
ehosctl secret list --app ledger --env ledger-try
pbpaste | ehosctl secret set smtp_password --app ledger --env ledger-try   # from the clipboard
ehosctl secret set smtp_password --app ledger --env production < password.txt
ehosctl secret rotate stripe_key --app ledger --env production --from-file stripe.key
ehosctl secret set smtp_password --app ledger --template small            # the template's default
ehosctl secret delete smtp_password --app ledger --env ledger-try
```

These do what the application's page in the console does with its secrets
([eh-os `docs/secrets-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/secrets-api.md)).
EHOS keeps the values in the installation, and nobody reads one back, an administrator included
(eh-os D-99). Setting and deleting need `ehos.secret.manage` there, which the application's
administrator holds; listing needs that or `ehos.application.deploy`.

- **Where** is `--env`, an environment of the application, or `--template`, the template's
  default for the application, which an ephemeral environment made from it gets when it has none
  of its own. Production has no template: it only ever gets its own.
- **A secret's name** is a lowercase word, and reaches every container of the workload as a
  variable of that name in upper case: `smtp_password` is `SMTP_PASSWORD`. A name the runtime or
  EHOS already sets there is refused, `invalid`, exit 2.
- **The value** is never an argument, which another process can read, and never typed at the
  terminal, which would show or keep it. `--from-file` takes the file as it is; otherwise it is
  read from standard input, a pipe or a file, to its end, less the one line break `echo` ends
  with: `pbpaste | ehosctl secret set …` on macOS, or `IFS= read -rs v && printf %s "$v" |
  ehosctl secret set …` in bash or zsh, where `IFS=` keeps leading and trailing spaces. It is
  UTF-8 text of at most 64 KiB, read no further than that, sent in the request's body alone, and
  never printed.
- **Each `set` is a new version**, and the deployments given the secret without a pin roll to it,
  which `set` counts; `rotate` is `set` under the name of what it does. A deployment that pins a
  version keeps it.
- **Deleting** removes a secret with every version. It asks first, unless `--yes`; without a
  terminal nothing is asked, so without `--yes` nothing is sent, exit 2. EHOS refuses it while a
  deployment that may be in force runs with it, `in_use`, exit 1, naming those deployments.
- **The secret store not answering** is `secrets_unavailable`, exit 5: nothing was set.
