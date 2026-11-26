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

When you make a server, `up` makes you its first installation administrator. After the first boot,
`up` adds you with the key that you log in with. By default, your name is your user name on your
workstation, from `USER`, else `LOGNAME`:

- `up` writes the name in lowercase.
- Each character other than a letter, a digit or a hyphen becomes a hyphen.
- The name starts at the first letter, and has 31 characters or fewer.

To give another name, use `--administrator`:

```sh
ehosctl server up --provider oci --administrator ada
```

If `up` cannot make a name from your user name, for example `1001`, it refuses to make a new
server, before it changes anything, and asks for `--administrator`. If `up` makes the server again,
as after `down`, it refuses after the apply. Run `ehosctl server up --administrator NAME` then.

Without `--administrator`, `up` names nobody:

- on a server that an `up` with another user name made, as in a folder copied from another
  workstation;
- on a server that has an installation administrator already;
- on a server that an earlier version of `ehosctl` made.

On a server that an `up` with another user name made, `up --administrator` refuses too. Ask an
installation administrator to add you with `admin add`. `up` tells the person who made the server
from another person by the user name alone: two people with the same user name, such as `ubuntu`,
are one person to it.

The report shows your name and your Kubernetes user. `up` then warns that one installation
administrator remains. Add a second one: if the only one loses their key, nobody can reach the
server over SSH.

## Add an installation administrator

Prerequisites:

- You are an installation administrator of the server, with the folder of the installation and the
  state passphrase.
- The new person has a workstation with `ehosctl`.

1. The new person makes a new key on their workstation:
   `ssh-keygen -t ed25519 -f ~/.ssh/ehos_<installation>`. If the shared key is in that file, they
   choose another name.
2. The new person sends you the `.pub` file. The `.pub` file is a public key. The private key stays
   on their workstation.
3. Run `ehosctl server admin add <name> --public-key <file>`. `ehosctl` takes one `ssh-ed25519` or
   `ecdsa-sha2-nistp256` key, with no options such as `from=`.
4. Compare the fingerprint that the report shows with the fingerprint of the person:
   `ssh-keygen -l -f ~/.ssh/ehos_<installation>.pub`. If the two differ, remove the person at once.
5. Give the person a copy of the folder of the installation and the state passphrase, as
   `ehosctl server handover` says.
6. The new person runs `ehosctl server tunnel --ssh-key ~/.ssh/ehos_<installation>`.
   `ehosctl` finds the person by their key on the server, records the name and the id on their
   workstation, and writes a kubeconfig with a certificate of their own.

`add` first writes the line in `authorized_keys`, then makes the ClusterRoleBinding. If `add`
stops between the two, run it again with the same name and key: it makes the ClusterRoleBinding
only.

## Remove an installation administrator

Run `ehosctl server admin remove <name>`. `ehosctl` first removes the line of the person in
`authorized_keys`. Then it removes the user of the person from each ClusterRoleBinding and
RoleBinding. It deletes a binding when no other subject is left in it. The certificates of the
person stop working at once, because no binding names their user any more.

If `remove` stops after it removed the line, the person cannot log in over SSH. A binding of the
person can stay. The person reaches the cluster with it only through an SSH tunnel that is still
open. Run the command again: it removes the bindings that are left.

`remove` refuses:

- the last installation administrator. An installation always has at least one. When one remains,
  `up`, `tunnel`, `admin list` and `doctor` warn.
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
  ServiceAccount. `admin list` shows each binding to `cluster-admin`;
- a kubeconfig with the administrator certificate of k3s, which `tunnel` wrote for them with
  `ehosctl` 0.49.0 or earlier, or with the shared key. That certificate is in the group
  `system:masters`, which no binding grants, so `remove` cannot take it back. It works for up to
  a year, and `admin list` cannot show it. Only a rotation of the client CA of the cluster ends
  it, which `ehosctl` does not do yet.

## See who can reach the server

`ehosctl server admin list` shows:

- each installation administrator, with the fingerprint of their key and their ClusterRoleBinding;
- each line in `authorized_keys` that names nobody, with the lines of the guest agent of GCP;
- each other subject bound to `cluster-admin`, or to a role that gives each verb on each resource.
  The subjects of k3s are not shown;
- each certificate signing request that the cluster still lists;
- a warning for a person who is in one place but not in the other.

`ehosctl doctor` shows the same, after its checks of this machine. It reads the server of the
installation that `--installation` or `EHOSCTL_INSTALLATION` names. If neither names one, it reads
the server of the current installation, if this computer keeps that server. Else it reads no
server. It does not count what it reads in its exit code.

## Move an installation made before

On an installation made before, each installation administrator has the same key, the shared key.
The shared key is the provisioning key, the key that the server took on its first boot.

1. Run `admin add` for each person, each with a new key of their own. The first `add` names the
   line of the shared key `ehos-administrator:shared`. On GCP, it adds a line with that name beside
   the line of the guest agent.
2. Each person runs `ehosctl server tunnel --ssh-key <their new key>`. This replaces the
   kubeconfig with the shared certificate of k3s on their workstation.
3. When each person has access of their own, remove the shared key: `admin remove shared`. On GCP,
   first give the key of one installation administrator to `up --provisioning-key`.

After step 3, `tunnel` refuses a key that is on the line of no person.

Step 3 does not end the copies of the administrator certificate of k3s that `tunnel` wrote before.
Each still works for up to a year. After step 3:

- Each person deletes the shared private key on their workstation.
- Each person deletes a kubeconfig that `tunnel` wrote with the shared key or with `ehosctl` 0.49.0
  or earlier, and runs `tunnel` again with their own key.

Only a rotation of the client CA of the cluster ends a copy that someone kept. `ehosctl` does not
do it yet.

`admin remove shared` refuses while no person has access of their own.

## The certificate in the kubeconfig

`ehosctl server tunnel` writes a kubeconfig with a key and a certificate of your own, when a line
on the server names you and holds the key that you log in with:

1. It makes an Ed25519 key on your workstation. The key does not leave it.
2. It makes a certificate signing request for your Kubernetes user, with no group, for 12 hours.
3. It checks the request that the cluster made, and approves it on the server, as root.
4. It checks that the certificate is for your key and lasts no longer than 12 hours, with
   10 minutes for the clock of the cluster, and writes the kubeconfig.

`tunnel` keeps the certificate while it has 1 hour or more left, and while the CA of the cluster
signed it. Else it issues a new one. If your kubeconfig is stolen, the thief has access for
12 hours at most, or until an installation administrator removes you.

`tunnel` reads the lines on the server each time, and records the name and the id of the person
whose line holds your key. So a folder of the installation that you copied from another
workstation does not give you the certificate of that person. If a person was removed and added
again, `tunnel` records their new id. With `--administrator <name>`, `tunnel` checks that the line
of that name holds your key.

If `tunnel` cannot read the lines, as while k3s restarts, it keeps the certificate in your
kubeconfig when these are true:

- your workstation records you, and you log in with the key whose line named you;
- the CA of the cluster signed the certificate, and it has 1 hour or more left.

Then it opens the tunnel, and warns. Otherwise it fails. It does not copy the administrator
certificate of k3s while it cannot read the lines.

If the key that you log in with is on the line of no person, and the server still has the shared
key, `tunnel` copies the administrator certificate of k3s, and warns. The server still has the
shared key when one of these is true:

- it has a line named `shared`;
- the provisioning key is on a line that names nobody, and on no person's line;
- no installation administrator has a key on the server yet.

That certificate is the same for each person, and works for a year. Ask an installation
administrator to add you, then run `tunnel` with your own key.

If the server has no shared key, `tunnel` refuses a key on the line of no person. So `tunnel` does
not copy the administrator certificate of k3s from a server where each person has a key of their
own. A person who can log in can still read that file on the server with `sudo`.

## What occurs when ehosctl writes authorized_keys

The guest agent of GCP and cloud-init also write `authorized_keys`. So `ehosctl` keeps the lines of
the guest agent of GCP as they are, and writes the file with care:

1. It takes a lock on the server. If another `ehosctl` holds the lock for 2 minutes, it stops, and
   changes nothing.
2. It writes the file only if the file did not change after `ehosctl` read it. If the file
   changed, `ehosctl` reads the server again and makes the change again from the new file. It keeps
   the lines that another program wrote. It tries the write 3 times at most, 2 seconds apart. It stops,
   and changes nothing, if the line of an installation administrator changed, or if the file
   changed each time. Run the command again.
3. It keeps the previous file, and puts the new file in place.
4. It logs in again with your key. If the server refuses the key, the server puts the previous file
   back within 60 seconds.

## Next steps

- [The server under an installation](server.md)
- [Hand the installation to another installation administrator](server-handover.md)
