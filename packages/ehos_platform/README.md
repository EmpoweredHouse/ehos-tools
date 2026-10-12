# ehos_platform

The code that makes the server under an EHOS installation and installs EHOS on it, shared by
eh-os's tooling (`mix ehos.cluster`, CI's Cluster job, the server check) and `ehosctl`'s platform
plane ([eh-os D-92](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0092-the-installation-code-is-a-package-in-ehos-tools-and-ehos-s-release-carries-the-chart-and-modules-it-installs.md)).

- `EhosPlatform.Server`: the server, from a provider's OpenTofu module, with k3s by cloud-init and
  the API server reached through an SSH tunnel. Its state is `~/.ehos/<name>/`.
- `EhosPlatform.Install`: CloudNativePG, cert-manager and trust-manager, the installation's CA, and
  EHOS's chart, with the image by digest.
- `EhosPlatform.Source`: what is installed, an eh-os checkout (`Source.checkout/1`) or a release
  (`Source.release/1`), whose chart is installed by digest and whose modules are checked by SHA-256.

It runs `tofu`, `helm`, `kubectl` and `ssh` through `EhosPlatform.CommandRunner`, and depends on
nothing of EHOS's.

    $ mix check   # format, warnings as errors, tests
