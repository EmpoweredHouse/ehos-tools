# Where the installation runs, and what it uses

```sh
ehosctl installation
ehosctl installation --json
```

This reads what the console's Installation page shows
([eh-os `docs/installation-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/installation-api.md)):

- the installation's name, provider, region and size, as its installer gave them, and the
  console's address;
- which version of EHOS runs, the commit it was built from, and when it was installed, from an
  EHOS that says so (eh-os 0.14.0 on; `ehos` under `--json`, `null` from an older one);
- whether four eyes holds on its promotions, and since when a change of it was recorded, from
  EHOS 0.14.0 (eh-os D-128, eh-os#749);
- each node, with its capacity and its CPU and memory now;
- each environment, with its quota, what its pods request against it, and what it and each of its
  applications use now.

It needs one of the platform capabilities, as the Environments page does; a refused read is
recorded, and exits 3. What EHOS could not read it says, and prints the rest: a cluster without
metrics-server has no usage. `--json` gives EHOS's reading, CPU in millicores and memory in bytes.
`ehosctl installations` is another command: the installations this machine knows.
