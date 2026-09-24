# ehosctl

The terminal's way into EHOS. Its first command needs no EHOS at all:

```sh
ehosctl init shop
```

creates `shop/`, a Phoenix application wired for EHOS, from the template pinned into this
binary (`lib/ehosctl/template.ex`): the Erlang and Elixir versions, the `phx_new` and
`igniter_new` archives, and the `ehos_app` installer. Everything runs under
`mise exec` with those versions, which mise installs precompiled on first use.

## Working on it

```sh
mix check
```

Build the binary for this machine (needs Zig 0.16.0 and xz):

```sh
MIX_ENV=prod BURRITO_TARGET=macos_arm mix release
```

`.tool-versions` here pins the toolchain ehosctl is *built* with. Burrito bundles the ERTS
of exactly that OTP version from its CDN, which lags the newest patch release; the build
fails with a 404 until it appears.

Two things that cost time during the spike:

- A `prod` Burrito binary unpacks its payload once per version and reuses it. Rebuilding
  without bumping the version runs the **old** code until
  `burrito_out/ehosctl_macos_arm maintenance uninstall`.
- `EHOSCTL_TEMPLATE_SOURCE=path:../ehos_app` points `init` at a local installer instead of
  the pinned one, for working on the template.
