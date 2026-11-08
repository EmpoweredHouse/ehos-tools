# Where the installation runs, and what it uses

`ehosctl installation` shows where the installation runs and the resources that it and its
applications use now. It reads what the Installation page of the console shows, through the API that
[eh-os `docs/installation-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/installation-api.md)
describes. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl installation
ehosctl installation --json
```

## What it shows

- The name, provider, region and size of the installation, as its installer gave them, and the
  address of the console.
- The version of EHOS that runs, the commit that it was built from, and when it was installed. EHOS
  0.14.0 and later say this. Under `--json` it is `ehos`, which is `null` from an older EHOS.
- If four eyes applies to promotions, and when EHOS recorded the last change of it. EHOS 0.14.0 and
  later say this.
- Each node, with its capacity and the CPU and memory that it uses now.
- Each environment, with its quota, what its pods request against the quota, and what the
  environment and each of its applications use now.

`--json` gives the reading of EHOS, with CPU in millicores and memory in bytes.

## What it needs

`installation` needs one of the platform capabilities, as the Environments page does. If EHOS
refuses the read, EHOS records the refusal, and `ehosctl` exits 3.

If EHOS could not read a part, `ehosctl` says so and prints the rest. A cluster without
metrics-server has no usage.

`ehosctl installations` is a different command: it lists the installations that this machine knows.

## The DNS records of the installation

An installation with public certificates needs DNS records at the DNS provider of your company.
`ehosctl installation domain` shows each record, its state at the last check of EHOS, and what to
change. It also shows the addresses of applications that have no certificate yet.

```sh
ehosctl installation domain
ehosctl installation domain --check --json
```

- `--check` makes EHOS check the records now. EHOS checks at most once a minute. EHOS also checks
  them each day.
- The command exits 1 after it prints, while a record is not there or EHOS finds a problem. A
  pipeline can run it until it exits 0.
- If EHOS does not know the values of the records, run `ehosctl install` again with `ehosctl`
  0.37.0 or later.

`ehosctl` does not say how a DNS provider takes a record. The console shows the same records at
`/installation/domain`, and the
[guide of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#make-the-dns-records-for-public-certificates)
says how to make each record.

## Next steps

- [Domains of your company](domains.md)
- [Installations that this machine knows](installations.md)
- [Upgrade EHOS](upgrade.md)
