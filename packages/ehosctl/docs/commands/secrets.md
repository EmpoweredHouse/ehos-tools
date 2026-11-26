# Secrets

These commands set, rotate, list and delete the secrets of an application, such as the password of
a mail server. They do what the page of the application in the console does with its secrets. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page, and
[`docs/secrets-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/secrets-api.md)
describes the API that they use.

```sh
ehosctl secrets list --app ledger --env ledger-try
pbpaste | ehosctl secrets set smtp_password --app ledger --env ledger-try   # from the clipboard
ehosctl secrets set smtp_password --app ledger --env production < password.txt
ehosctl secrets rotate stripe_key --app ledger --env production --from-file stripe.key
ehosctl secrets set smtp_password --app ledger --template small            # the default of an environment template
ehosctl secrets delete smtp_password --app ledger --env ledger-try
```

EHOS keeps the values in the installation. Nobody can read a value back, also not a person who
holds `ehos.administrator`. `set`, `rotate` and `delete` need `ehos.secret.manage` in the place of
the secret. The administrators of the application hold it. `list` needs `ehos.secret.manage` or
`ehos.application.deploy`.

## Choose where the secret applies

Each command needs one place:

- `--env <environment>`: an environment of the application.
- `--template <environment template>`: the default of the application in that environment
  template. An ephemeral environment made from the environment template gets this value if it has
  no value of its own.

A production environment is not made from an environment template, so it gets only its own value.

## Name a secret

The name of a secret is a word in lowercase. Each container of the workload gets it as a variable
with the same name in uppercase: `smtp_password` becomes `SMTP_PASSWORD`. If the runtime or EHOS
already sets a variable with that name, EHOS refuses the name with `invalid`, and `ehosctl` exits
with 2.

## Set or rotate a value

1. Put the value in a file, or send it through a pipe.
2. Run `ehosctl secrets set <name> --app <application> --env <environment>`, with the value on
   standard input or with `--from-file <path>`.

`--from-file` reads the file as it is. From standard input, `ehosctl` reads to the end and removes
one line break at the end, as `echo` adds. Examples:

- On macOS: `pbpaste | ehosctl secrets set …`.
- In bash or zsh: `IFS= read -rs v && printf %s "$v" | ehosctl secrets set …`. `IFS=` keeps the
  spaces at the start and at the end.

`ehosctl` does not take the value as an argument, because another process can read it. It does not
read the value from a terminal, because the terminal can show or keep it. So it refuses a
`--from-file` path to a device, such as `/dev/tty`. The value is UTF-8 text
of 64 KiB or less. `ehosctl` sends it only in the body of the request and never prints it.

If you run `set` or `rotate` on a terminal without a value, `ehosctl` sets nothing and gives the
command to run instead: your command, with the value read by your shell and sent through a pipe.
The shell does not show the value, and does not keep it in its history. In zsh:

```text
ehosctl: Nothing was set.
  ehosctl does not read the value of smtp_password from a terminal, which can show or keep it. It reads the value from a pipe, or from the file that --from-file names.
What to do:
  For a value of several lines or of more than 1000 bytes, give --from-file. For a shorter value of one line, run this command in zsh. It does not show what you type:
  (unset v; set +ax; IFS= read -rs 'v?Value of smtp_password: ' && echo && printf '%s' "$v" | ehosctl secrets set smtp_password --app ledger --env ledger-try --installation office)
```

The command runs in a subshell, so the value is gone when the command ends, also after Ctrl-C.
`set +ax` keeps the value out of the environment of `ehosctl` and out of a trace of the shell.
`read` stops at the first line break, so give a value of several lines with `--from-file`.
`ehosctl` gives the command for zsh or bash, as the variable `SHELL` names. For another shell, it
gives no command: use `pbpaste` or `--from-file`. A shell reads a line from a terminal only to a
limit, which is 1 KiB on macOS: a longer paste does not end, so give a longer value, such as a key
in PEM, with `--from-file`.

Each `set` makes a new version. Each deployment that got the secret without a pin rolls to the new
version, and `ehosctl` shows how many. A deployment that pins a version keeps that version.
`rotate` does the same as `set`.

If the secret store does not answer, EHOS refuses with `secrets_unavailable`, and `ehosctl` exits
with 5. Nothing was set.

## Delete a secret

Run `ehosctl secrets delete <name> --app <application> --env <environment>`. The command deletes
the secret and all its versions.

`ehosctl` asks before it deletes. To delete without a question, give `--yes`. Where nobody can
answer, as in a pipe, `ehosctl` does not ask. Without `--yes`, it sends nothing and exits with 2.

EHOS refuses with `in_use` while a deployment that can be in force runs with the secret.
`ehosctl` exits with 1 and names those deployments.

## Next steps

- [Environments and resources](env.md): the environments of an installation.
- [Environment templates](env-template.md): the environment templates that ephemeral
  environments are made from.
