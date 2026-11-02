# Installations

`ehosctl` keeps the installations of EHOS that you know under names that you give them. One of them
is current, as kubectl keeps its contexts. This page says how a command chooses an installation, and
where `ehosctl` keeps them. The
[glossary of eh-os](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/architecture/glossary.md)
defines the words of this page.

```sh
ehosctl installations list
ehosctl installations use staging
ehosctl installations remove local
```

## How a command chooses the installation

A governed command talks to the first installation in this list:

1. the installation that `--installation <name>` names;
2. the installation that `EHOSCTL_INSTALLATION` names;
3. the address that `EHOSCTL_URL` gives, from a GitHub Actions job (see
   [Deploying from GitHub Actions](github-actions.md));
4. the current installation.

## Where ehosctl keeps them

`ehosctl` keeps them in `config.json`, in `$EHOSCTL_CONFIG_DIR`, else `$XDG_CONFIG_HOME/ehosctl`,
else `~/.config/ehosctl`, also on macOS. The file holds no secret:

```json
{
  "version": 1,
  "current": "staging",
  "installations": {
    "local": {"url": "https://ehos.localhost"},
    "staging": {"url": "https://ehos.staging.example.com"}
  }
}
```

- `ehosctl` writes the whole file and renames it into place.
- It creates the directory readable only by you, and refuses a directory that others can write to.
- If `config.json` is a link, as a dotfiles manager makes it, `ehosctl` writes the file through the
  link.

## Add, choose and forget an installation

- `ehosctl login <url>` adds an installation. `ehosctl login` signs in to one again.
- `installations use <name>` makes an installation the current one.
- `installations remove <name>` forgets an installation. It does not end its sign-in: run
  `ehosctl logout` first.

## Background

- [T-07: ehosctl keeps installations as named contexts in a JSON file](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md)

## Next steps

- [Sign in](login.md)
- [Where the installation runs, and what it uses](installation.md)
