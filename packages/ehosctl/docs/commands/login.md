# Signing in

`ehosctl login https://ehos.example.com` opens your browser at EHOS's log-in page, where you type
your password; `ehosctl` never sees it
([eh-os D-89](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0089-ehosctl-signs-a-person-in-as-a-public-client-through-a-loopback-redirect-and-gets-each-credential-by-renewal.md)).
The browser comes back to `ehosctl` on `127.0.0.1`, on a port it picks. If the browser does not
open, `ehosctl` prints the address to open by hand. On a machine you reach over SSH, forward that
port, or sign in on your own machine.

- **The address** is an origin: `https://` and a host, with a port if it needs one, and nothing
  after it. EHOS signs no one in over plain HTTP, so neither does `ehosctl`.
- **An installation with a CA of its own**, which your system does not trust: a server's, whose
  CA is `~/.ehos/<name>/ca.crt` on the machine that made it, or the k3d cluster's at
  `https://ehos.localhost`, `_build/k3d/ca.crt`. Name it once, at `login`, in `EHOSCTL_CA_FILE`, a
  PEM file of CA certificates `ehosctl` trusts besides the system's, as `curl --cacert` does:

  ```sh
  EHOSCTL_CA_FILE=<path to eh-os>/_build/k3d/ca.crt ehosctl login https://ehos.localhost
  ```

  `login` keeps the certificates beside the installation in `config.json`, and every later
  command to that installation trusts them, with no variable set (T-14); `installations list`
  shows `own` in its CA column. Signing in again without the variable keeps them, and with it
  replaces them, as when the installation's CA changed; `installations remove`, then `login`,
  drops them. A `config.json` that holds a CA, and the directory it is in, must be yours and
  writable by no one else, as `ehosctl` makes them; one others can change is refused, and so is
  writing a CA through a link to one. Set for any other command, the variable
  is trusted too. `ehosctl` reads it before it connects: a file it cannot read, one larger than
  1 MiB, or one with a certificate in it that does not decode, is named and exits 2. Requests to
  GitHub, which `versions` and `changelog` make, trust the system's CAs alone.
- **The installation** is kept under `--installation <name>`, or under a name made from the host:
  `ehos.staging.example.com` is `staging`, and this machine is `local`. It becomes the current
  one. `ehosctl login` with no address signs in again to the current installation, or to the one
  `--installation` names.
- **How long it lasts.** Seven days from when you typed your password, or three days without a
  command that renews it, whichever comes first. EHOS can end it sooner: when you change your
  password, when someone disables your account, or when the terminal is signed out from the
  console, with `ehosctl terminals sign-out` or by a people manager. `ehosctl whoami` says until
  when.
- **Where it is kept**
  ([T-08](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0008-ehosctl-keeps-a-sign-in-s-refresh-token-in-the-system-s-keychain-else-a-file-only-the-user-reads-and-renews-under-a-lock.md)).
  The refresh token goes in the system's keychain: Keychain on macOS, the Secret Service on Linux
  (it needs `secret-tool`, from `libsecret-tools`). Without one, it goes in a file only you can
  read, and `login` says so. `EHOSCTL_TOKEN_STORE=file` chooses the file. Beside it, in
  `$EHOSCTL_STATE_DIR`, else `$XDG_STATE_HOME/ehosctl`, else `~/.local/state/ehosctl`, are the
  ten-minute credentials it renews, each kept until it expires, the two endpoints a renewal and
  `logout` post to, so they read EHOS's discovery document only when those move, and a lock that
  keeps two commands from renewing at once. Who you are and until when is in `config.json`,
  beside the installation.
- **`ehosctl logout`** ends the sign-in at EHOS, then forgets it here. When EHOS does not answer,
  it forgets the sign-in all the same, and says that EHOS was not told. It signs out neither your
  browser, a sign-in of its own, nor your other terminals.
- **`ehosctl terminals`** lists every terminal you are signed in on, newest first, as your
  settings in the console do: when each signed in, when it last renewed, and when it ends at the
  latest, in UTC, with its id in full. It does not say which is the one this `ehosctl` runs on:
  EHOS does not say which sign-in a credential belongs to. `--json` gives
  `{"terminals": [...]}`, each with EHOS's four fields.
- **`ehosctl terminals sign-out <id>`** signs one of them out, as the console does: it can no
  longer renew, so its commands stop within ten minutes. EHOS records it. A terminal that has ended
  or is not yours is "signed out already", exit 1, and not recorded. To sign out every one of your
  terminals, sign out each; `ehosctl logout` signs out only the one it runs on.
