# Domains of your company

A production application can answer at a domain of your company, such as
`ledger.client.example`, in place of its own address. These commands list, map, show and remove
such domains. They do what the Domains page of the console does, through the API that
[eh-os `docs/installation-api.md`](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/installation-api.md)
describes. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl domains
ehosctl domains map ledger.client.example --app ledger --env production
ehosctl domains map api.client.example --app ledger --env production --entry api
ehosctl domains show ledger.client.example
ehosctl domains remove ledger.client.example
```

## What you need

- An installation with public certificates. See
  [Get the certificates from Let's Encrypt](install.md#get-the-certificates-from-lets-encrypt).
- A domain of your company in the allowed domains of the installation. See
  [Allow domains of your company](install.md#allow-domains-of-your-company).
- `ehos.domain.manage` at the whole platform. Only `ehos.administrator` grants it.

## Map a domain

1. Run `ehosctl domains map <domain> --app <application> --env <environment>`. The environment
   must be a production environment. `--entry` names a public entry of the application. The
   default is `web`.
2. Make the `CNAME` record that the command prints, at the DNS provider of the domain.
3. Run `ehosctl domains show <domain>` until the state is `active`.

EHOS checks the record 1 minute after the mapping. After each check that does not agree, it waits
two times longer, at most 1 hour. When the record is correct, EHOS gets a certificate for the
domain from Let's Encrypt. Then the application answers at the domain.

`ehosctl` does not say how a DNS provider takes a record. The console shows the domain at
`/domains/<domain>`, and the
[guide of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/INSTALLING.md#make-the-dns-records-for-public-certificates)
says how to make a record.

## Read the state of a domain

`ehosctl domains` lists each domain with its application, environment, entry and state.
`ehosctl domains show <domain>` also shows the record, the last check, what to change, and the
time of the next check.

| State | What it means |
| --- | --- |
| waiting for DNS | EHOS waits for a correct `CNAME` record. |
| issuing | The record is correct. EHOS waits for the certificate of the domain. |
| active | The application answers at the domain. |

A later EHOS adds more states. `ehosctl` shows a state that it does not know as EHOS gives it.

Both commands exit 1 after they print, while a domain is not `active`. A pipeline can run
`ehosctl domains show <domain>` until it exits 0. `--json` gives the fields of the mapping that
`ehosctl` knows, as EHOS gives them.

## Remove a domain

Run `ehosctl domains remove <domain>`. The application stops answering at the domain. `ehosctl`
asks first. `--yes` removes without a question. Then you can remove the record at the DNS provider.

## Next steps

- [The DNS records of the installation](status.md#the-dns-records-of-the-installation)
- [Installing EHOS on the server](install.md)
