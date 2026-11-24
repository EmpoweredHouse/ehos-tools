# The installation administrators of a server

Each installation administrator reaches the server with an SSH key of their own. So you can take
the access of one person away and keep the access of the others. The `ehosctl server admin`
commands add, remove and list the installation administrators of a server. This page is for the
installation administrator. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl server admin list                              # who can reach the server, and how
ehosctl server admin add bob --public-key bob.pub      # give bob access with a key of their own
ehosctl server admin remove bob                        # take the access of bob away
```

These are platform commands. They change the server over SSH, with the key that you log in with.
They read the address of the server from the state, so they need the state passphrase. They need
no cloud account.

## What an installation administrator has on the server

An installation administrator has a name, an id of 8 hexadecimal digits that `ehosctl` makes, and
one public SSH key. A name has 1 to 31 lowercase letters, digits and hyphens, and starts with a
letter. The server keeps each installation administrator in two places:

- A line in `/home/ubuntu/.ssh/authorized_keys`: `<key> ehos-administrator:<name>:<id>`. With this
  line, the person logs in to the server as `ubuntu`, who has `sudo`.
- A ClusterRoleBinding `ehos-administrator-<name>-<id>`, which binds the Kubernetes user
  `ehos-administrator:<name>:<id>` to `cluster-admin`.

If you remove a person and add them again with the same name, they get a new id. So the new
person is a new Kubernetes user.

## Name the first installation administrator of a new server

Give your name to `up` when you make the server:

```sh
ehosctl server up --provider oci --administrator ada
```

After the first boot, `up` adds you with the key that you log in with. The report shows your name
and your Kubernetes user. `up` then warns that one installation administrator remains. Add a
second one: if the only one loses their key, nobody can reach the server over SSH.

## Add an installation administrator

Prerequisites:

- You are an installation administrator of the server, with the folder of the installation and the
  state passphrase.
- The new person has a workstation with `ehosctl`.

1. The new person makes a new key on their workstation:
   `ssh-keygen -t ed25519 -f ~/.ssh/ehos_<installation>`.
2. The new person sends you the `.pub` file. The `.pub` file is a public key. The private key stays
   on their workstation.
3. Run `ehosctl server admin add <name> --public-key <file>`. `ehosctl` takes one `ssh-ed25519` or
   `ecdsa-sha2-nistp256` key, with no options such as `from=`.
4. Compare the fingerprint that the report shows with the fingerprint of the person:
   `ssh-keygen -l -f ~/.ssh/ehos_<installation>.pub`. If the two differ, remove the person at once.
5. Give the person a copy of the folder of the installation and the state passphrase, as
   `ehosctl server handover` says.
6. The new person runs `ehosctl server tunnel --ssh-key ~/.ssh/ehos_<installation>`.

`add` first writes the line in `authorized_keys`, then makes the ClusterRoleBinding. If `add`
stops between the two, run it again with the same name and key: it makes the ClusterRoleBinding
only.

## Remove an installation administrator

Run `ehosctl server admin remove <name>`. `ehosctl` removes the user of the person from each
ClusterRoleBinding and RoleBinding. It deletes a binding when no other subject is left in it. Then
it removes the line of the person in `authorized_keys`.

`remove` refuses:

- the last installation administrator. An installation always has at least one. When one remains,
  `up`, `tunnel`, `admin list` and `doctor --installation` warn.
- on GCP, the person whose key the metadata of the instance holds. The guest agent of GCP writes
  that key back. First give the key of another installation administrator to
  `up --provisioning-key`, then remove the person.
- a change that removes the key that you log in with. Ask another installation administrator to
  remove you.

`remove` does not end the other ways in of the person:

- an SSH session that is open;
- their access to the cloud account, which can put a key on the server or make the server again;
- their copy of the state and its passphrase;
- an address in `--ssh-from` that only they use. Run `up` with the addresses of the others;
- access that they made while they were an installation administrator, such as a binding or a
  ServiceAccount. `admin list` shows each binding to `cluster-admin`.

## See who can reach the server

`ehosctl server admin list` shows:

- each installation administrator, with the fingerprint of their key and their ClusterRoleBinding;
- each line in `authorized_keys` that names nobody, with the lines of the guest agent of GCP;
- each other subject bound to `cluster-admin`, or to a role that gives each verb on each resource.
  The subjects of k3s are not shown;
- each certificate signing request that the cluster still lists;
- a warning for a person who is in one place but not in the other.

`ehosctl doctor --installation <name>` shows the same, after its checks of this machine. It does
not count it in its exit code.

## Move an installation made before

On an installation made before, each installation administrator has the same key, the shared key.
The shared key is the provisioning key, the key that the server took on its first boot.

1. Run `admin add` for each person, each with a new key of their own. The first `add` names the
   line of the shared key `ehos-administrator:shared`. On GCP, it adds a line with that name beside
   the line of the guest agent.
2. Each person runs `ehosctl server tunnel --ssh-key <their new key>`.
3. When each person has access of their own, remove the shared key: `admin remove shared`. On GCP,
   first give the key of one installation administrator to `up --provisioning-key`.

`admin remove shared` refuses while no person has access of their own.

## What occurs when ehosctl writes authorized_keys

The guest agent of GCP and cloud-init also write `authorized_keys`. So `ehosctl` keeps the lines of
the guest agent of GCP as they are, and writes the file with care:

1. It takes a lock on the server. If another `ehosctl` holds the lock for 2 minutes, it stops, and
   changes nothing.
2. It writes the file only if the file did not change after `ehosctl` read it. Else it stops, and
   changes nothing. Run the command again.
3. It keeps the previous file, and puts the new file in place.
4. It logs in again with your key. If the server refuses the key, the server puts the previous file
   back within 60 seconds.

## Next steps

- [The server under an installation](server.md)
- [Hand the installation to another installation administrator](server-handover.md)
