# End the shared admin certificate of k3s

On an installation made before each installation administrator had a key of their own, `tunnel`
copied the admin certificate of k3s to each workstation. That certificate works for up to a year,
and nobody can revoke it. `ehosctl server rotate-client-ca` replaces the client CA of the cluster,
so that the cluster no longer accepts any certificate of the old client CA. This page is for the
installation administrator. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl server admin list           # each person has a key of their own, and no shared key
ehosctl server rotate-client-ca     # replace the client CA, then the server token of k3s
ehosctl server tunnel               # each installation administrator, for a new certificate
```

This is a platform command. It changes the server over SSH, with the key that you log in with. It
reads the address of the server from the state, so it needs the state passphrase. It needs no
cloud account.

## Prerequisites

- Each installation administrator has a key of their own, and the shared key is gone. Do steps 1
  to 3 of [Move an installation made before](server-admin.md#move-an-installation-made-before).
  `rotate-client-ca` refuses to start before. With the shared key, a person can copy the admin
  certificate of k3s again.
- EHOS is installed on the server. `rotate-client-ca` records what it does on the Deployments of
  the governance plane and of the operator.
- The disk of the server has room for 2 copies of `/var/lib/rancher/k3s/server`, and 512 MiB more.

## Before you start

Tell the people of the installation that EHOS stops. While the rotation runs:

- The governance plane and the operator of EHOS have zero replicas. Nobody can sign in to the
  console or to an application. A sign-in from before keeps working until it expires.
- k3s restarts 3 times. Each time, the Kubernetes API does not answer for about 15 seconds. The
  pods of the applications keep running.

On a test server, EHOS was stopped for about 6 minutes.

Change nothing in the cluster while the rotation runs. If the rotation fails, `ehosctl` puts back
a copy of k3s from before the rotation, and a change after the copy is lost.

## Rotate the client CA

1. Run `ehosctl server admin list`. Make sure that it shows each person with a key of their own,
   and no line named `shared`.
2. Run `ehosctl server rotate-client-ca`. `ehosctl` shows each step on the server.
3. When it ends, each installation administrator runs `ehosctl server tunnel` on their own
   workstation. Their certificate was from the old client CA, so `tunnel` issues a new one.

The report says that the server has a new client CA. The admin certificate of k3s that `tunnel`
copied before no longer works, and the certificate of each installation administrator from before
no longer works.

## What the rotation does

`ehosctl` starts the rotation as a process on the server, in a systemd unit of its own. So the
rotation goes on when your SSH connection stops. The process reaches the cluster with
`sudo k3s kubectl` on the server, because your own certificate stops working at the second
restart. The process does these steps:

1. It checks the room on the disk.
2. It records the replica counts of the governance plane and of the operator, and the fingerprint
   of the client CA, in annotations on their Deployments. Then it scales both to zero, and waits
   until no pod of either is left, for 5 minutes at most.
3. It stops k3s, copies `/var/lib/rancher/k3s/server` to `/var/lib/ehosctl/client-ca/copy`, and
   starts k3s. The copy holds each key of the cluster. Only root can read it.
4. It makes a new client CA on the server, with a P-256 key of its own. The other CAs and keys of
   the cluster stay the same.
5. It gives the new client CA to `k3s certificate rotate-ca`, and restarts k3s.
6. It replaces the server token of k3s with `k3s token rotate`, and restarts k3s. The token comes
   after the restart. Before the restart, it would put the old client CA back.
7. It checks that the Kubernetes API accepts the new admin certificate of k3s and refuses the old
   one, and that the node is Ready.
8. It scales EHOS back to the recorded counts, deletes the copy, and removes the annotations. A
   Deployment that someone scaled while the rotation ran keeps their count.

`ehosctl` follows the process for 45 minutes at most. If it stops following, the process goes on.
Run `ehosctl server rotate-client-ca` again to follow it.

## What occurs when a step fails?

Before the checks of step 7 pass, a failed step undoes the rotation:

- If the copy is complete, the process stops k3s, puts the copy back, and starts k3s. It checks
  that the old admin certificate works and that the node is Ready. Then it scales EHOS back,
  deletes the copy and removes the annotations. `ehosctl` fails, and says that the shared admin
  certificate works again. Run the command again.
- If the copy is not complete, the client CA did not change. The process scales EHOS back. If k3s
  does not start, EHOS stays at zero, and `ehosctl` says so. Repair k3s over SSH, then run the
  command again.
- If the process cannot put the copy back, or the cluster does not come back on it, the process
  keeps the copy and leaves EHOS at zero. `ehosctl` says where the copy is. Over SSH,
  `sudo systemctl status k3s` and `sudo journalctl -u k3s` show why k3s does not start. Repair
  it, then run the command again. Once the copy is in place, a run again never puts it back a
  second time: it starts k3s on it, checks the old admin certificate and the node, then scales
  EHOS back and deletes the copy.

The copy does not hold what a controller or a person wrote in the cluster after the copy. The
controllers of CloudNativePG and cert-manager are examples. EHOS writes nothing in that time,
because it is stopped. On a test server, CloudNativePG and cert-manager wrote their state again
after the copy was put back.

After the checks pass, the rotation is not undone, also not by a run again: the process records on
the disk that they passed. If the process cannot scale EHOS back, delete the copy or remove the
annotations, it tries 5 times. Then `ehosctl` fails. Run the command again to finish it.

Each wait of the process, for the Kubernetes API, the node or the pods of EHOS, ends after 5
minutes by the clock.

If another `ehosctl` starts a rotation after yours read the server, yours follows it while it runs.
If that rotation has ended, yours starts nothing, and says so. Run `ehosctl server admin list` to
see the state of the server.

## What occurs when the process stops?

If the server restarts or the process stops, EHOS stays at zero. If k3s was stopped, k3s and the
applications stay down too. A copy of each key of the cluster can stay on the disk.
`ehosctl server admin list` and `ehosctl doctor --installation NAME` show each of these.

Run `ehosctl server rotate-client-ca` again. The process starts k3s, and decides from the client CA
on the disk and the annotations:

| What the server holds | What the process does |
| --- | --- |
| The checks passed | It finishes. It never puts the copy back. If k3s does not start, `ehosctl` says so: repair k3s over SSH, then run the command again. |
| An undo put the copy back | It starts k3s, checks the old admin certificate and the node, then scales EHOS back, deletes the copy and removes the annotations. It never puts the copy back a second time. |
| The client CA changed, the copy is complete, and the token rotation is recorded | It runs the checks, then finishes. |
| The client CA changed, the copy is complete, and the token rotation is not recorded | It replaces the token and restarts k3s, runs the checks, then finishes. |
| The client CA changed, the copy is not complete, and the token rotation is recorded | It checks the new admin certificate and the node, then finishes. |
| The client CA changed, the copy is not complete, and the token rotation is not recorded | It scales EHOS back and removes the annotations. The server token stays the old one. Run the command again to replace both. |
| The client CA did not change, and the copy is complete | It puts the copy back, as when a step fails. |
| The client CA did not change, and the copy is not complete | It scales EHOS back, and deletes what there is of the copy. |
| A copy, and no annotations | It deletes the copy. It never puts it back. |
| No copy and no annotations | It changes nothing. Run the command again to start a rotation. |

If an annotation records a replica count that is not a whole number from 0 to 10, the process
refuses it and changes nothing. Correct the annotation, then run the command again.

## What the rotation does not end

- The server CA, the request-header CA and the key of the service accounts stay the same. So the
  pods and their tokens keep working. Whoever copied one of these keys keeps what it gives.
- A ServiceAccount token, a binding or a workload that someone made. `admin list` shows each
  binding to `cluster-admin`.
- Access to the cloud account, a copy of the state and its passphrase, and an SSH session that is
  open.

## Next steps

- [The installation administrators of a server](server-admin.md)
- [The server under an installation](server.md)
