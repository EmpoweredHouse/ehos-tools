# ehos_platform

The code that makes the server under an EHOS installation and installs EHOS on it, shared by
eh-os's tooling (`mix ehos.cluster`, CI's Cluster job, the server check) and `ehosctl`'s platform
plane ([eh-os D-92](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0092-the-installation-code-is-a-package-in-ehos-tools-and-ehos-s-release-carries-the-chart-and-modules-it-installs.md)).

- `EhosPlatform.Server`: the server, from a provider's OpenTofu module, with k3s by cloud-init and
  the API server reached through an SSH tunnel. Its state is `~/.ehos/<name>/`.
- `EhosPlatform.Install`: CloudNativePG, cert-manager, trust-manager and Traefik, the
  installation's CA, and EHOS's chart, with the image by digest; and EHOS's release command that
  invites a person and prints their sign-in link (`invite/1`).
- `EhosPlatform.Source`: what is installed, an eh-os checkout (`Source.checkout/1`) or a release
  (`Source.release/1`), whose chart is installed by digest and whose modules are checked by SHA-256.

It runs `tofu`, `helm`, `kubectl` and `ssh` through `EhosPlatform.CommandRunner`, reads the
environment through `EhosPlatform.Env`, waits through `EhosPlatform.Clock` and asks for this
machine's public address through `EhosPlatform.PublicAddress`: behaviours a caller's tests replace
in `opts` ([T-20](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0020-code-in-ehos-tools-and-the-applications-it-generates-is-behaviour-driven-with-hammox-mocks.md)).
It depends on nothing of EHOS's.

    $ mix check   # audit, format, warnings as errors, Credo, tests, Dialyzer
