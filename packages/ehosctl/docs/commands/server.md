# The server under an installation

```sh
export EHOS_STATE_PASSPHRASE=…        # encrypts OpenTofu's state; keep it with your passwords
ehosctl doctor                        # the tools and the cloud account these commands need
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
