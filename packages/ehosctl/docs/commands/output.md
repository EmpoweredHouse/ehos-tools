# Output and exit codes

This page tells where `ehosctl` writes its output and its errors, and what each exit code means.
It is for a person or a script that runs `ehosctl`. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

## Read the output

A command writes words for a person on stdout. A command that takes `--json` writes one JSON
document there instead, for a script. A command without `--json` refuses the flag as an invalid
command line.

Errors go to stderr:

- as words for a person, in this shape;
- with `--json`, as one JSON object: `{"error": {"kind": "invalid", "message": "…"}}`.

```text
ehosctl changed nothing.
  office lists the database ledger already. This command only adds a database.
What to do:
  To take it out of the list, run:
  ehosctl resources remove-database ledger --installation office
```

1. The first line says what happened, after `ehosctl:`. When the line starts with the name
   `ehosctl`, the name is not written two times: `ehosctl changed nothing.`, not
   `ehosctl: ehosctl changed nothing.`.
2. The indented lines under it say why, when the first line does not say it already.
3. `What to do:` gives a sentence of advice, and each command to run on a line of its own. A
   command is complete: copy it and run it. A word in capitals, such as `ENVIRONMENT`, is a value
   that you replace.

Under `--json`, `message` is one paragraph with all of this, and the commands are also a list,
`what_to_do`.

If EHOS refused the request with a code, the JSON object also has the code, as `code`:
`{"error": {"kind": "failed", "message": "…", "code": "in_use"}}`. A gateway that answers in place of
EHOS sends no code, and the object then has none. The code stays the same when EHOS changes the
sentence, so a script can compare the code. The
[refusals page of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/refusals.md) lists
the codes. Some refusals have more fields:
[Find what holds the maximum number of ephemeral environments](env.md#find-what-holds-the-maximum-number-of-ephemeral-environments).

If stderr is a terminal, `ehosctl` also writes lines for a person there. Before a command that acts
on an installation runs, a line names the installation: `Installation: office
(https://ehos.office.example)`. After a command, a line can say that a newer `ehosctl` is released.
`ehosctl` does not write these lines under `--json`, or when the variable `CI` is set. The commands
`login`, `verify`, `versions` and `changelog` choose the installation themselves and write no
installation line: `login` and `versions` name it in their own output.

## What each exit code means

The exit code gives the kind of the error. Each kind keeps its code from one version to the next.

| Code | Kind | Meaning |
| --- | --- | --- |
| 0 | | The command is done. |
| 1 | `failed` | The command failed, and says why. See [Exit code 1](#exit-code-1). |
| 2 | `invalid` | `ehosctl` does not accept the command line. See [Exit code 2](#exit-code-2). |
| 3 | `refused` | EHOS or the application refused the request, because none of your roles grants it. |
| 4 | `not_signed_in` | You are not signed in. Run `ehosctl login`. See [Exit code 4](#exit-code-4). |
| 5 | `unreachable` | The installation or the application did not answer. See [Exit code 5](#exit-code-5). |

### Exit code 1

The command failed for a reason that it names. `ehosctl` also exits with 1 in these cases:

- The thing that the request names does not exist, or EHOS erased it.
- The request conflicts with what is there now.
- The EHOS of the installation is too old to have the route of the command.

### Exit code 2

`ehosctl` does not accept the command line: an unknown command, option or name. `ehosctl` also
exits with 2 in these cases:

- The application says that the fields do not fit.
- `ehosctl` cannot use a variable, such as an `EHOSCTL_CA_FILE` with no certificate in it.

### Exit code 4

You are not signed in, your sign-in has expired or ended, or EHOS did not accept the credential.
Run `ehosctl login`. `ehosctl` also exits with 4 when no installation is current, or when it does
not know the installation that you name.

### Exit code 5

The installation or the application did not answer, or asked you to try again later. `ehosctl`
also exits with 5 when a command stops waiting for something that can still change, such as a
deployment that is still `activating`.

## How a refusal gets its exit code

`ehosctl` shows a refusal in the words of the console, from
[`docs/refusals.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/refusals.md) of
eh-os. The kind of the refusal there gives the exit code:

- Refused: 3.
- Not signed in and Not accepted: 4.
- Invalid: 2.
- Unavailable: 5.
- Not found, Conflict and Gone: 1.

## When the EHOS of an installation is too old

Each call to EHOS goes to its versioned API, `/api/v1`. If an installation answers that it does not
have a route, `ehosctl` reads the routes that `GET /api/v1` lists. Instead of a 404, `ehosctl` says
that the EHOS of the installation, at the version that it names, is too old for the command. It
says that the operator must upgrade EHOS, and exits with 1. If an installation has no `/api/v1`,
`ehosctl` says that it is older than this `ehosctl`.

## When ehosctl init fails

`init` is the exception. When one of its steps fails, `init` exits with the exit code of that step.
It also says what it leaves behind, and under `What to do:` the commands that you run:

- a directory that it did not finish, which you remove before you try again;
- or, if it generated the project already, the setup steps that you do yourself, and the first
  commit.

## Next steps

- [Signing in](login.md): what to do when `ehosctl` exits with 4.
- [Calling an application](call.md): the refusals of an application.

## Background

- [eh-os D-91](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0091-every-component-releases-the-same-way-and-says-which-interfaces-it-produces-and-accepts.md):
  why each call goes to the versioned API.
