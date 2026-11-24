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

## Before you start

- The installation has a server on this machine: `ehosctl server up` made it here, or you restored
  a copy of the installation.
- Give `--email` with the email of the person. Without it, the commands say `EMAIL` in its place.

## What the command prints

The sections come in this order:

1. **If the person needs to be an installation administrator.** An installation administrator gets
   root on the server and administrator access to the cluster, and you cannot take this access back
   yet. A developer who deploys applications does not need it. Invite a developer as a person, and
   give them the CA file only.
2. **What goes in the shared password manager:** the state passphrase, a copy of the installation
   and the SSH key. The copy leaves out the files that `ehosctl` writes again. On Google Cloud the
   person can make a key of their own instead. Their `ehosctl server up --ssh-key` puts it on the
   server in place of yours. On the other providers, a new key makes the server again.
3. **OpenBao's key, which you do not hand over.** The person reads it from the cluster with their
   kubeconfig. The copy outside the server is a backup for a lost server. If `ehosctl install` did
   not warn you of the key on this machine, the section gives the command that makes the backup.
4. **What the person makes for themselves:** a sign-in to the cloud account, and their own
   `GITHUB_TOKEN` and `GHCR_TOKEN`. The sign-in has the role that the provider needs, such as
   `roles/compute.admin` on Google Cloud.
5. **How to let the person into EHOS:** an invitation, and the role `ehos.administrator` on the
   whole platform.
6. **The certificates.** With certificates from Let's Encrypt, the person signs in with no CA file.
   With the own CA of the installation, the section gives the CA file and its SHA-256 fingerprint,
   which you send over another channel.
7. **Who owns the state.** Only one person runs `ehosctl server up` and `down`, until the state is
   shared and locked. The section gives the addresses that SSH admits now, and the `up` that adds
   the address of the person.
8. **What the person runs on their machine:** restore the copy, `server up --ssh-key`,
   `server tunnel`, `install --version` with the version that runs, and `login`.
9. **The steps in the password manager.** If the 1Password CLI, `op`, is on the path, the section
   gives its commands. The state passphrase goes to `op` through a pipe, from
   `EHOS_STATE_PASSPHRASE`, so it shows on no command line. The copy goes to `op` with no file on
   the disk. Without `op`, the section gives the steps in the 1Password app and in Apple Passwords.

## Limits

- Apple Passwords holds no files. Keep the copy of the installation and the SSH key in another place
  that only the installation administrators can read.
- The 1Password CLI cannot read back an SSH key that it saved. Import the SSH key in the 1Password
  app.
- `ehosctl` does not know the version of EHOS that runs without the cluster. The command says
  `VERSION`, and `ehosctl versions` shows it.
- `ehosctl` cannot pack or encrypt the copy of the installation yet. The command prints the `tar`
  command that makes it.

## JSON

With `--json`, the command prints one object with the facts of the installation and the sections.
The facts are the provider and its place, the SSH key, the addresses that SSH admits, the
certificates, the host of the console and the email. Each section has an `id`, a `title` and its `parts`. Each part has a `text` and its
`commands`.

## Next steps

- [The server under an installation](server.md)
- [Inviting a person as the operator](server-invite.md)
- [Share an installation with another installation administrator](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#share-an-installation-with-another-installation-administrator),
  in the installation guide of eh-os
