# Output and exit codes

A command prints words for a person on stdout. One that takes `--json` prints one JSON document
there instead, for a script; a command without it refuses `--json` as an invalid command line.
Errors go to stderr: one line, `ehosctl: …`, or under `--json` one JSON object,
`{"error": {"kind": "invalid", "message": "…"}}`.

The exit code says what kind of error it was, and a kind keeps its code from one version to the
next:

| Code | Kind | Meaning |
| --- | --- | --- |
| 0 | | Done |
| 1 | `failed` | The command failed for a reason of its own, which it names. Also what the request names does not exist, conflicts with what is there now, or was erased, or the installation's EHOS is too old to have the command's route |
| 2 | `invalid` | The command line is not one `ehosctl` accepts: an unknown command, option or name, or fields an application says do not fit. Also a variable `ehosctl` cannot use, such as an `EHOSCTL_CA_FILE` with no certificate in it |
| 3 | `refused` | EHOS or the application refused the request: none of your roles grants it |
| 4 | `not_signed_in` | Not signed in, or the sign-in has expired or ended, or the credential was not accepted: run `ehosctl login`. Also when no installation is current, or the one named is unknown |
| 5 | `unreachable` | The installation or the application did not answer, or asked to be tried again later. Also what a command waited for that may still change when its wait ends, as a deployment still `activating` |

A refusal is said in the words the console uses, eh-os's
[`docs/refusals.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/refusals.md), and its
kind there gives the code: Refused is 3, Not signed in and Not accepted are 4, Invalid is 2,
Unavailable is 5, and Not found, Conflict and Gone are 1.

Every call to EHOS goes to its versioned API, `/api/v1` (eh-os
[D-91](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0091-every-component-releases-the-same-way-and-says-which-interfaces-it-produces-and-accepts.md)).
When an installation answers that it has no such route, `ehosctl` reads the routes it lists at
`GET /api/v1` and says that its EHOS, at the version it names, is too old for the command, and
that the operator upgrades EHOS, instead of a bare 404; it exits 1. An installation without
`/api/v1` at all is said to be older than this `ehosctl`.

`init` is the exception: when one of its steps fails, it exits with that step's own exit code. It
also says what is left behind: a half-generated directory to remove before trying again, or, when
the project was already generated, the one setup step to finish by hand.
