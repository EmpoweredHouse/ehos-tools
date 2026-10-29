# Installations

The installations of EHOS you know are kept under names you give them, one of them current, as
kubectl keeps its contexts
([T-07](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0007-ehosctl-keeps-installations-as-named-contexts-in-a-json-file-in-the-users-config-directory.md)).
A governed command talks to the one `--installation <name>` names, else the one
`EHOSCTL_INSTALLATION` names, else the address `EHOSCTL_URL` gives, from a GitHub Actions job
(see [Deploying from GitHub Actions](github-actions.md)), else the current one.

They are kept in `config.json`, in `$EHOSCTL_CONFIG_DIR`, else `$XDG_CONFIG_HOME/ehosctl`, else
`~/.config/ehosctl`, on macOS too. The file holds no secret:

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

`ehosctl` writes it whole and renames it into place, creates its directory readable only by you,
and refuses a directory others can write to. A `config.json` that is a link, as a dotfiles manager
makes it, is rewritten through the link.

`ehosctl login <url>` adds an installation, and `ehosctl login` signs in to one again.
