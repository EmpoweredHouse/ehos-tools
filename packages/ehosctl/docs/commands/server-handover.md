# Handing an installation to another installation administrator

`ehosctl server handover` prints what another installation administrator needs to take over an
installation, and the commands that each of you runs. This page is for the installation
administrator who gives the installation. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl server handover --installation acme --email ada@example.com
ehosctl server handover --installation acme --json
```

The command reads the files of the installation in `~/.ehos/<name>/` and the configuration of
`ehosctl`. It contacts nothing, changes nothing and shows no secret. Each command that it prints
and that writes a secret to a file starts with `umask 077`, so that only you can read the file.
The commands are for a POSIX shell, such as sh, bash or zsh. fish reads them in another way.

## Before you start

- The installation has a server on this machine: `ehosctl server up` made it here, or you restored
  a copy of the installation.
- Give `--email` with the email of the person. Without it, the commands say `EMAIL` in its place.

## What the command prints

The sections come in this order:

1. **If the person needs to be an installation administrator.** An installation administrator gets
   root on the server and administrator access to the cluster. `ehosctl server admin remove` takes
   back their own key, and takes their user out of each binding. It does not take back the key that every
   administrator shared while the server has it, a copy of the state, or access that the person
   made. A developer who
   deploys applications does not need it. Invite a developer as a person, and
   give them the CA file only.
2. **What goes in the shared password manager:** the state passphrase and a copy of the
   installation. The copy leaves out the files that `ehosctl` writes again. You do not hand over
   an SSH key.
3. **How to add the person to the server.** The person makes an SSH key of their own, in
   `~/.ssh/ehos_<installation>_admin`, and sends you its `.pub` file. You run
   `ehosctl server admin add` with it, and compare the fingerprint with theirs. If this workstation
   has no installation administrator of its own yet, the section first gives the commands that add
   you. It also gives the `admin remove` that the person runs if you leave, and the
   `admin remove shared` that ends the shared key once each administrator has a key of their own
   ([The installation administrators of a server](server-admin.md)). On Google Cloud, the `up`
   before it keeps the address of the person, so that SSH still admits them.
4. **OpenBao's key, which you do not hand over.** The person reads it from the cluster with their
   kubeconfig. The copy outside the server is a backup for a lost server. If `ehosctl install` did
   not warn you of the key on this machine, the section gives the command that makes the backup.
5. **What the person makes for themselves:** a sign-in to the cloud account, and their own
   `GITHUB_TOKEN` and `GHCR_TOKEN`. The sign-in has the role that the provider needs, such as
   `roles/compute.admin` on Google Cloud. On Oracle Cloud, the section names the profile of
   `~/.oci/config` that their `server up` reads, with the tenancy and the region of the server.
6. **How to let the person into EHOS:** an invitation, and the role `ehos.administrator` on the
   whole platform.
7. **The certificates.** With certificates from Let's Encrypt, the person signs in with no CA file.
   With the own CA of the installation, the section gives the CA file and its SHA-256 fingerprint,
   which you send over another channel.
8. **Who owns the state.** Only one person runs `ehosctl server up` and `down`, until the state is
   shared and locked. The section gives the addresses that SSH admits now, and the `up` that adds
   the address of the person.
9. **What the person runs on their machine:** restore the copy, give the shell the state
   passphrase, `server up` and `server tunnel` with their own key,
   `install --version` with the version that runs, and `login`. Their `server tunnel` writes a
   kubeconfig with a certificate of their own. Their `server up` keeps each address that SSH
   admitted when `server handover` ran, so run `server handover` again before a later `up`.
   On AWS and OVHcloud it names their own profile or entry in `clouds.yaml`.
10. **The steps in the password manager.** If the 1Password CLI, `op`, is on the path, the section
   gives its commands. The state passphrase goes to `op` through a pipe, from
   `EHOS_STATE_PASSPHRASE`, so it shows on no command line. If the variable is not set or is
   empty, `op` makes no item. `tar` writes the copy to a temporary
   file that only you can read, and `op` gets it only if `tar` succeeds. The command removes the
   file, also when you stop it. A later copy replaces the first in the same document. Without
   `op`, the section gives the steps in the 1Password app and in Apple Passwords.

## Limits

- Apple Passwords holds no files. Keep the copy of the installation in another place that only the
  installation administrators can read.
- `ehosctl` does not know the version of EHOS that runs without the cluster. The command says
  `VERSION`, and `ehosctl versions` shows it.
- `ehosctl` cannot pack or encrypt the copy of the installation yet. The command prints the `tar`
  command that makes it.

## JSON

With `--json`, the command prints one object with the facts of the installation and the sections.
The facts are the provider and its place, the SSH key, the addresses that SSH admits, the
installation administrator of this workstation, the certificates, the host of the console and the email. Each section has an `id`, a `title` and its `parts`. Each part has a `text` and its
`commands`.

## Next steps

- [The server under an installation](server.md)
- [Inviting a person as the operator](server-invite.md)
- [The installation administrators of a server](server-admin.md)
- [Share an installation with another installation administrator](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#share-an-installation-with-another-installation-administrator),
  in the installation guide of eh-os
