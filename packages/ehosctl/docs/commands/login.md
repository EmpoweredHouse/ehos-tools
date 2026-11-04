# Signing in

`ehosctl login` signs you in to an installation of EHOS in your browser. This page also tells how
long a sign-in lasts, where `ehosctl` keeps it, and how to sign out. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl login https://ehos.example.com
ehosctl whoami
ehosctl terminals
ehosctl logout
```

## Sign in

`ehosctl login https://ehos.example.com` opens your browser at the log-in page of EHOS. You type
your password there. `ehosctl` never sees your password.

1. The browser comes back to `ehosctl` on `127.0.0.1`, on a port that `ehosctl` chooses.
2. If the browser does not open, `ehosctl` shows the address. Open it yourself.
3. If you reach the machine over SSH, forward that port, or sign in on your own machine.

The address is an origin: `https://` and a host, with a port if it needs one, and nothing after
it. EHOS does not sign people in over plain HTTP, so `ehosctl` does not either.

`ehosctl` keeps the installation under the name that `--installation <name>` gives. Without it,
`ehosctl` keeps a new installation under the name that the installation gives itself, which its
console also shows. `ehosctl` makes a name from the host instead in these cases:

- The installation gives no name, or a name that `ehosctl` cannot use. A name has lowercase
  letters, digits and dashes, and starts with a letter.
- Another installation on this machine has that name.

From the host, `ehos.staging.example.com` is `staging`, and this machine is `local`. If another
installation on this machine has that name too, `ehosctl` refuses: give `--installation`. An
installation that `ehosctl` knows already keeps its name. The installation becomes the current
installation.

If you keep an installation under another name than its own, each sign-in tells you its own
name: `The installation names itself office.`

`ehosctl login` with no address signs you in again to the current installation, or to the
installation that `--installation` names.

## Sign in to an installation with its own CA

Some installations use a CA that your system does not trust:

- A server: its CA is `~/.ehos/<name>/ca.crt` on the machine that made the server.
- The k3d cluster at `https://ehos.localhost`: its CA is `_build/k3d/ca.crt`.

Give the CA one time, at `login`, in `EHOSCTL_CA_FILE`. The variable names a PEM file of CA
certificates. `ehosctl` trusts them in addition to the CAs of the system, as `curl --cacert` does.

```sh
EHOSCTL_CA_FILE=<path to eh-os>/_build/k3d/ca.crt ehosctl login https://ehos.localhost
```

- `login` keeps the certificates beside the installation in `config.json`. Each later command to
  that installation trusts them, without the variable. `installations list` shows `own` in its CA
  column.
- If you sign in again without the variable, `ehosctl` keeps the certificates. If you sign in
  again with the variable, `ehosctl` replaces them, for example when the CA of the installation
  changed.
- To remove the certificates, run `installations remove`, and then `login`.
- A `config.json` that contains a CA must be yours and writable only by you, and its directory
  too. `ehosctl` makes them so. `ehosctl` refuses a file that other people can change, and it does
  not write a CA through a link to such a file.
- If you set the variable for another command, `ehosctl` trusts it too.
- `ehosctl` reads the file before it connects. `ehosctl` names the file and exits with 2 if:
  - it cannot read the file;
  - the file is larger than 1 MiB;
  - a certificate in the file does not decode.
- Requests to GitHub, which `versions` and `changelog` send, trust only the CAs of the system.

## How long a sign-in lasts

A sign-in lasts 7 days from when you typed your password. It ends sooner if no command renews it
for 3 days. EHOS can end it before that:

- when you change your password;
- when someone disables your account;
- when someone signs out the terminal: you in the console, you with `ehosctl terminals sign-out`,
  or a people manager.

`ehosctl whoami` shows who you are signed in as, and until when.

## Where ehosctl keeps your sign-in

`ehosctl` keeps the refresh token in the keychain of the system: Keychain on macOS, or the Secret
Service on Linux. The Secret Service needs `secret-tool`, from `libsecret-tools`.

If the system has no keychain, `ehosctl` keeps the token in a file that only you can read, and
`login` says so. To use the file, set `EHOSCTL_TOKEN_STORE=file`.

The state directory is `$EHOSCTL_STATE_DIR`, else `$XDG_STATE_HOME/ehosctl`, else
`~/.local/state/ehosctl`. It contains:

- the credentials of 10 minutes that `ehosctl` renews, each until it expires;
- the two endpoints that a renewal and `logout` send requests to, so `ehosctl` reads the discovery
  document of EHOS only when they move;
- a lock that stops two commands from renewing at the same time.

`config.json` keeps who you are and until when, beside the installation.

## Sign out

`ehosctl logout` ends the sign-in at EHOS, and then removes it from this computer. If EHOS does not
answer, `ehosctl` removes the sign-in all the same, and says that EHOS did not receive the
sign-out. EHOS then ends the sign-in itself, at the latest 3 days after its last use.

`logout` does not sign out your browser, which has its own sign-in, or your other terminals.

## See and sign out your terminals

`ehosctl terminals` lists each terminal where you are signed in, the newest first, as your settings
in the console do. For each terminal, it shows its full id and three times in UTC: the sign-in, the
last renewal, and the latest end.

`ehosctl terminals` does not show which terminal runs this `ehosctl`, because EHOS does not say
which sign-in a credential belongs to. With `--json`, the output is `{"terminals": [...]}`, each
with the four fields of EHOS.

`ehosctl terminals sign-out <id>` signs out one terminal, as the console does. The terminal cannot
renew its sign-in, so its commands stop within 10 minutes. EHOS records the sign-out.

- If the terminal has ended or is not yours, EHOS says that it is signed out already. `ehosctl`
  exits with 1, and EHOS records nothing.
- To sign out all your terminals, sign out each one. `ehosctl logout` signs out only the terminal
  that it runs on.

## Next steps

- [Calling an application](call.md): use your sign-in to call an application.
- [Output and exit codes](output.md): what each exit code means.

## Background

- [eh-os D-89](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0089-ehosctl-signs-a-person-in-as-a-public-client-through-a-loopback-redirect-and-gets-each-credential-by-renewal.md):
  why `ehosctl` signs in through the browser and a loopback address.
- [T-08](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0008-ehosctl-keeps-a-sign-in-s-refresh-token-in-the-system-s-keychain-else-a-file-only-the-user-reads-and-renews-under-a-lock.md):
  why the refresh token goes in the keychain, else in a file.
- [T-14](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0014-ehosctl-login-keeps-the-ca-it-was-told-to-trust-beside-the-installation-and-trusts-it-for-that-installation-alone.md):
  why `ehosctl` keeps the CA of an installation in `config.json`.
