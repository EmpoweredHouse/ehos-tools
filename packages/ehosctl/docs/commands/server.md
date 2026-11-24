# The server under an installation

The `ehosctl server` commands make, reach, read and remove the server of an installation, in Oracle
Cloud, AWS, GCP or OVHcloud. `ehosctl doctor` checks that this machine can run them. This page is
for the installation administrator. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
export EHOS_STATE_PASSPHRASE=…        # encrypts the state of OpenTofu; keep it with your passwords
ehosctl doctor                        # the tools, cloud account and GitHub token these commands need
ehosctl server up --provider oci      # make the server; wait until k3s runs on it
ehosctl server tunnel                 # an SSH tunnel to its Kubernetes API, and a kubeconfig
ehosctl server status                 # its address, CPUs, memory and load, first boot and node
ehosctl server down                   # remove it and all on it, after you type its name
```

These are platform commands. They act with your cloud account and your SSH key, never with a
sign-in, and they read no data of an application.

## Choose the installation

The installation is the one that `--installation` names. Else it is `EHOSCTL_INSTALLATION`, else the
current installation, else `trial`. The files of its server are in `~/.ehos/<name>/`, where
`mix ehos.server` keeps them. So `ehosctl` reads a server that Mix made as it is.

- `status`, `tunnel`, `down`, `install` and `upgrade` refuse a name that has no server on this
  machine, before anything runs. The refusal names the installations that have a server.
- A server made before `ehosctl login` named installations after their host is under `trial`. The
  current installation then has the name of the host, so give `--installation trial`.
- `up` makes a new server under the name that you give. Without `--installation`, it makes one under
  the current installation or `trial` only when no other installation has a server. Otherwise it
  asks for `--installation`.
- The OpenTofu module refuses a name longer than 16 characters, so such a name cannot be the name of
  a new server.

Each command that these commands suggest, such as the tunnel after `up`, names the installation. So
it reaches the same server, whichever installation is current when you run it.

## Check this machine before the first server

Run `ehosctl doctor` before the first `up`. It checks what `up` needs, prints a line for each item,
and changes nothing:

- OpenTofu, Helm and kubectl at the versions that EHOS is tested with, and `ssh`.
- The cloud accounts that it can see, one line for each provider.
- The GitHub token that `up` reads the releases of EHOS with: `MISE_GITHUB_TOKEN`, else
  `GITHUB_TOKEN`. Set one, for example to the output of `gh auth token`.
- `GHCR_TOKEN`, which `ehosctl install` needs later.
- `psql`, version 16 or later, which `ehosctl db connect` starts. `doctor` does not count it in its
  exit code, because `up` does not need it.

`doctor` exits 0 when the tools, `ssh` and the GitHub token are there, and it finds the account of
at least one provider. It does not count a refused, blocked or incomplete account. Otherwise it
exits 1, after it prints the report.

### What doctor checks on GCP

If gcloud is installed and credentials are present, `doctor` contacts Google. It asks gcloud for an
access token from the credentials, and never prints the token. With a project from `--gcp-project`,
else `GOOGLE_CLOUD_PROJECT`, it also reads the organisation policies of the project. It reads them
as the active account of gcloud (`gcloud auth login`). gcloud stops each request that Google does
not answer in 20 seconds. This limit applies to one request, not to all requests of gcloud.

- `compute.requireOsLogin`: if it is enforced, the server admits only OS Login users. `up` then
  waits for SSH that never admits its key.
- `compute.vmExternalIpAccess`: if it denies all external IP addresses, `up` cannot make the server.
  If it allows only the instances that it lists, it must list
  `projects/<project>/zones/<zone>/instances/ehos-<installation>`.

The line of a GCP account can say:

- `refused`: the credentials give no access token, or `GOOGLE_APPLICATION_CREDENTIALS` names no
  file. The line gives the command that renews them.
- `blocked`: an organisation policy stops `up`. Ask an organisation administrator to lift it for the
  project.
- `incomplete`: no project is given, or the project is not a GCP project ID.

The line of a policy can say `limits`: `compute.vmExternalIpAccess` allows an external IP address
only to the instances that it lists. The line names the instance that the list must have. A `limits`
line does not change the result.

A policy line that says "not checked" gives the reason, and the command that fixes it if there is
one. An example is the Organization Policy API, when it is off in the project. A policy that
`doctor` did not check does not change the result. If gcloud fails for a reason that is not about
the credentials, such as no network, the account still counts. The line says why `doctor` could not
check it.

## Make the server

The OpenTofu modules of a release of EHOS describe the server. `up` keeps them beside the
installation, in `~/.ehos/<name>/release/`, with the `release.json` of the release.

1. `up` uses the release that it kept, or the release that `--version` names. The first time, it
   uses the newest release.
2. `up` downloads the `release.json` and the archive of the modules from GitHub.
3. `up` checks the archive against the SHA-256 that `release.json` names, before it unpacks it. This
   check shows that the archive is the one that the release names. It does not show who published
   the release.
4. `up` keeps the release only after it succeeds.

To move a server to the modules of a newer release, run `up --version <version>`, and read the plan
that it shows.

After `up` keeps a release, `tunnel`, `status` and `down` use it with no network, and refuse another
`--version`. A server made with `mix ehos.server` has no release kept. The first time that one of
these commands runs, it takes the newest release, or the release that `--version` names, and keeps
it. `ehosctl` needs a GitHub token to read the releases of EHOS while they are private, as
`ehosctl versions` does.

### The options of up

`up` takes the options of `mix ehos.server`:

- `--provider`: `oci`, `aws`, `gcp` or `ovh`. A new server needs it. A server stays with its
  provider.
- `--region`, `--aws-profile`, `--gcp-project`.
- `--os-cloud`: on OVHcloud, the entry in `clouds.yaml` of OpenStack. By default `OS_CLOUD`, else
  `ovh`.
- `--ssh-key`, and `--ssh-from`, which you can repeat.
- `--availability-domain`, `--ocpus`, `--memory-gb`, `--instance-type`.
- `--replace`: without it, `up` refuses a plan that removes or replaces the server.
- `--public-certificates`: opens port 53, over UDP and TCP, for an installation that gets its
  certificates from Let's Encrypt (`ehosctl install --public-certificates`). A later `up` keeps it.
  The modules of an EHOS release before 0.27.0 cannot open port 53. `up` refuses them, and changes
  nothing: give `--version` with 0.27.0 or later.

### Log in with the right key

`up` records the path of the key that it logs in with, never the key. `tunnel`, `status`,
`install --switch-traefik`, `upgrade --switch-traefik` and a later `up` log in with that key, unless
you give another `--ssh-key`.

- An installation that `up` did not run on yet logs in with `~/.ssh/ehos_oci`. `up` refuses to put
  that key on the server in place of another key.
- Before they connect, `tunnel` and `status` say when the `.pub` of the key is not the one that `up`
  put on the server.
- If the server refuses the key, the error names the key and says to give the right one with
  `--ssh-key`.

## Reach and read the server

`tunnel` opens an SSH tunnel to the Kubernetes API of the server, and writes its kubeconfig. It
takes `--port`. `status` reads the CPUs, the memory and the load of the node before it asks
Kubernetes, so it shows them when EHOS is stopped.

## Remove the server

You cannot undo `down`. EHOS makes no backups yet. `down` removes:

- the server and its disk, with the database of EHOS and the database of each application on it;
- its network;
- its public address, which the provider can give to anyone. Remove the address from each rule that
  admits it, such as the rule of a mail relay.

`down` says this, with the provider, the region and the console of the installation. It removes
nothing until you type the name of the installation. A `y`, another name or no answer exits 1.

`--yes` asks nothing. `ehosctl` accepts it only with `--installation` on the command line, so a
script names the server that it removes in its own text. If a script pipes the name in, it also
names the server.

On AWS and GCP, the modules of EHOS ask the provider to protect the server. The provider then
refuses a deletion from its console, its API or its CLI.

- On GCP, this protection also refuses a stray `tofu destroy`. So `down`, and `up --replace` when
  the plan replaces the server, lift the protection first, and change nothing else. If they stop
  after this, they say so, and give the command to run next: `down` again to finish, or `up`, which
  turns the protection on again.
- On AWS, the module of EHOS makes OpenTofu lift the termination protection when it removes the
  server (`force_destroy`).
- Oracle and OVHcloud have no such protection on an instance.

`down` keeps the folder of the installation on your computer, `~/.ehos/<installation>/`. The
folder holds the encrypted state and the variables of the server. `ehosctl server up` makes the
server again from them. `down` gives the place of the state, and a warning with the command that
removes the folder. If you do not make the server again:

1. Remove the folder.
2. Remove the copy of the folder and the state passphrase from the password manager that the
   installation administrators share. Keep the passphrase if another installation uses it. Keep
   the SSH key if you use it for another server. Keep OpenBao's key while you keep its snapshots.
3. If `ehosctl` knows the installation, `down` gives a second warning with two commands. Run
   them. `ehosctl logout` removes your sign-in to the installation from this computer.
   `ehosctl installations remove` removes the installation from the list of `ehosctl`.

## Next steps

- [Install EHOS on the server](install.md)
- [Invite the first person](server-invite.md)
- [Hand the installation to another installation administrator](server-handover.md)
