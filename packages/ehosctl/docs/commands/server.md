# The server under an installation

```sh
export EHOS_STATE_PASSPHRASE=…        # encrypts OpenTofu's state; keep it with your passwords
ehosctl doctor                        # the tools, cloud account and GitHub token these commands need
ehosctl server up --provider oci      # make the server; wait until k3s runs on it
ehosctl server tunnel                 # an SSH tunnel to its Kubernetes API, and a kubeconfig
ehosctl server status                 # its address, CPUs, memory and load, first boot and node
ehosctl server down                   # remove it and everything on it, once its name is typed
```

These are platform commands: they act with your cloud account and SSH key, never with a
sign-in, and they reach no application's data. The installation is the one `--installation`
names, else `EHOSCTL_INSTALLATION`, else the current one, else `trial`, and its server's files
are in `~/.ehos/<name>/`, where `mix ehos.server` kept them, so a server made with it is read as
it is. `status`, `tunnel`, `down`, `install` and `upgrade` refuse a name no server's state is kept
under, before anything runs, and name the installations that have one: a server made before
`ehosctl login` named installations after their host is under `trial`, while the current
installation has the host's name, so give it `--installation trial`. `up` makes a new server
under the name it is given; under a name it was not given, the current installation's or
`trial`, it makes one only when no other installation has a server, and otherwise asks for
`--installation`. A name the OpenTofu module refuses, longer than 16 characters, cannot name a
new server. Every command these commands suggest, such as opening the tunnel after `up`, names
the installation, so it reaches the same server whichever installation is current when you run
it.

Run `ehosctl doctor` before the first `up`. It checks what `up` needs, prints a line for each
thing, and changes nothing:

- OpenTofu, Helm and kubectl at the versions EHOS is tested with, and `ssh`.
- The cloud accounts it can see, one line for each provider.
- The GitHub token that `up` reads EHOS's releases with: `MISE_GITHUB_TOKEN`, else
  `GITHUB_TOKEN`. Set one, for example to `gh auth token`.
- `GHCR_TOKEN`, which `ehosctl install` needs later.

On GCP, with gcloud installed and credentials present, `doctor` contacts Google. It asks gcloud
for an access token from the credentials, and never prints the token. With a project from
`--gcp-project`, else `GOOGLE_CLOUD_PROJECT`, it also reads the organisation policies in effect
for the project, as gcloud's active account (`gcloud auth login`). gcloud stops each request
that Google does not answer in 20 seconds; this does not limit how long all of gcloud's
requests take:

- `compute.requireOsLogin`: if it is enforced, the server admits only OS Login users, and `up`
  waits for SSH that never admits its key.
- `compute.vmExternalIpAccess`: if it denies all external IP addresses, `up` cannot make the
  server. If it allows only the instances it lists, it must list
  `projects/<project>/zones/<zone>/instances/ehos-<installation>`.

A GCP account line can say:

- `refused`: the credentials give no access token, or `GOOGLE_APPLICATION_CREDENTIALS` names no
  file. The line gives the command that renews them.
- `blocked`: an organisation policy stops `up`. Ask an organisation administrator to lift it for
  the project.
- `incomplete`: no project is given, or the project is not a GCP project ID.

A policy line can say `limits`: `compute.vmExternalIpAccess` allows an external IP address only
to the instances that it lists. The line names the instance that the list must have. A `limits`
line does not change the result.

A policy line that says "not checked" gives the reason, for example that the Organization Policy
API is off in the project, and the command that turns it on. A policy that is not checked does
not change the result. If gcloud fails for a reason that is not about the credentials, such as
no network, the account still counts, and the line says why it could not be checked.

`doctor` exits 0 when the tools, `ssh` and the GitHub token are there and at least one provider's
account is found. Refused, blocked and incomplete accounts are not counted. Otherwise it exits 1,
after it prints the report.

The server is described by the OpenTofu modules of an EHOS release, kept beside the
installation in `~/.ehos/<name>/release/` with the release's `release.json`. `up` uses the release
it kept, or the one `--version` names, or, the first time, the newest: it downloads that
release's `release.json` and modules' archive from GitHub, checks the archive against the SHA-256
`release.json` names before it unpacks it, and keeps the release only once `up` has succeeded.
That checks the archive is the one the release names, not who published the release. To move a
server to a newer release's modules, run `up --version <version>`, and read the plan it shows.

Once a release is kept, `tunnel`, `status` and `down` use it with no network, and refuse another
`--version`. A server made with `mix ehos.server`, which kept none, takes the newest release the
first time one of them runs, or the one `--version` names, and keeps it. Reading eh-os's releases needs a GitHub token while it
is private, as `ehosctl versions` does.

`up` takes `mix ehos.server`'s options: `--provider` (`oci`, `aws`, `gcp` or `ovh`), which a server
not made yet needs and a made one keeps, `--region`, `--aws-profile`, `--gcp-project`, `--os-cloud`
(on OVHcloud, the entry of OpenStack's `clouds.yaml`, `OS_CLOUD`'s or `ovh` unless given),
`--ssh-key`, `--ssh-from` (repeated), `--availability-domain`, `--ocpus`, `--memory-gb`,
`--instance-type`, and `--replace`, without which a plan that would remove or replace the server is
refused. `tunnel` takes `--port`. `status` reads the node's CPUs, memory and load before it asks
Kubernetes, so it reports them with EHOS stopped.

`down` cannot be undone: it removes the server and its disk, with EHOS's database and every
application's on it, its network, and its public address, which the provider may give to anyone, so
take it out of whatever admits it, such as a mail relay's rule; EHOS makes no backups yet. It says
so, with the installation's provider, region and console, and removes nothing until the
installation's name is typed: a `y`, another name or no answer exits 1. `--yes` asks nothing, and is
taken only with `--installation` on the command line, so a script names in its own text the server
it removes; piping the name in names it too. On AWS and GCP, EHOS's modules ask the provider to
refuse deleting the server from its console, its API or its CLI. On GCP that refuses a stray `tofu
destroy` as well, so `down`, and `up --replace` when the plan replaces the server, lift the
protection first, changing nothing else, and say so when they stop after it, with what to run next:
`down` again to finish, or `up`, which turns it back on. On AWS, EHOS's module has OpenTofu lift
termination protection as it removes the server (`force_destroy`). Oracle and OVHcloud have no such
protection on an instance.
