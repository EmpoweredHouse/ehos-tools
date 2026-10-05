# Changelog

All notable changes to `ehosctl` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehosctl` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered.

A release pins one template (`lib/ehosctl/template.ex`), so every change to a pin is listed here:
it changes what `ehosctl init` generates.

## [Unreleased]

### Fixed

- The READMEs say that mise, from 2026.10, reads a release's attestations with the token it is
  given, so a fine-grained token needs *Attestations: read*. CI's `install` job, which failed on
  every platform for v0.1.0 with a 403 from that API, has the permission.
- The READMEs say where mise finds a token: in the environment, or in `gh`'s `hosts.yml`, which
  stays empty when `gh` keeps its token in the system's keyring, as it does by default. Without
  one, GitHub answers mise with a 404 for the private repository. They lead with a fine-grained
  token, and show how to pass `gh`'s for one command.
- The moduledoc of `Ehosctl.Template` says the contract engine is the one part of the template a
  release does not pin: `ehos_app` follows eh-os-contract's `main`
  ([T-04](../../docs/adr/0004-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md)).

## [0.1.0] - 2026-10-03

The first release of `ehosctl`: one binary for each of macOS and Linux, on arm64 and x86_64,
that creates an EHOS application from `ehos_app` 0.4.0. While ehos-tools is private, it is an
internal release: `mise use -g github:EmpoweredHouse/ehos-tools@0.1.0` installs it with a GitHub
token that can read the repository. There is no Homebrew tap yet.

### Added

- The template is `packages/ehos_app` of ehos-tools at `9ba6f3e`, the commit the tag
  `ehos_app-v0.4.0` names, not at the tag: a tag can be moved, and the template is code the new
  project runs as its installer, so a new project's `mix.exs` names that commit, with
  `"== 0.4.0"` as its requirement, so that the project does not compile against another
  release. `init` generates the Phoenix project first, then installs it there with a `sparse:`
  dependency through `Igniter.Util.Install.install/2`, since `igniter.new --install` cannot name
  a subdirectory, and makes the project's first commit last.
- `EHOSCTL_TEMPLATE_SOURCE` takes `path:<absolute path>` or `ref:<git ref of ehos-tools>`.
- `init` writes a dash in the name as an underscore, which an OTP application's name needs, and
  says so. A name ends with a letter or a digit, as the DNS label EHOS makes of it does.
- `ehosctl init <name>` creates an EHOS application from the pinned template:
  - it runs `mix igniter.new --with phx.new` and installs `ehos_app` in the new project, under the
    pinned toolchain through `mise exec`;
  - it keeps the generator's archives in a directory owned by this version;
  - it finishes with Hex installed and `.tool-versions` trusted by mise.
- When `init` fails, it says what is left behind: a half-generated directory to remove before
  trying again, or the one setup step to finish by hand in a project that was generated.
- `ehosctl --version` and `ehosctl --help`.
- `EHOSCTL_TEMPLATE_SOURCE` replaces the pinned `ehos_app` source, for working on the template.
- A Burrito release, one self-contained binary for each of macOS and Linux, on arm64 and x86_64.
- `ehosctl init --help` prints the usage of `init`.
- Linux support on x64 and arm64, next to macOS. CI has an end-to-end job for each of the four
  platforms.
- Releases carry the four binaries and a `SHA256SUMS` file, and install with
  `mise use -g github:EmpoweredHouse/ehos-tools`.

### Changed

- The targets, and so the binaries, are named `macos_arm64`, `macos_x64`, `linux_arm64` and
  `linux_x64`, which mise's `github:` backend recognises.
- The missing-mise message links to mise's installation page instead of suggesting Homebrew.
- `init` gives each step the terminal's own stdin, stdout and stderr, so a prompt can be answered
  and errors stay on stderr.

### Fixed

- `init` installs the pinned Erlang and Elixir with `mise install --quiet` before its first
  `mise exec`, which cannot install a missing Elixir.
- A failed step is reported with the command that ran it (`mise …`), and a failed toolchain install
  says that mise builds Erlang from source where it has no precompiled build.
- An unexpected exception in the binary ends in one line on stderr and exit code 1, not a kernel
  crash report.
- An archive whose install was interrupted is installed again instead of being taken as present.
- `ehosctl --version x` and the other flags refuse extra arguments with a clear message.
- An empty `EHOSCTL_TEMPLATE_SOURCE` is taken as unset.

### Pins

- Erlang 28.5.0.7
- Elixir 1.20.4-otp-28
- `phx_new` 1.8.14
- `igniter_new` 0.5.34
- `ehos_app` `packages/ehos_app` of ehos-tools at `9ba6f3e`, the commit `ehos_app-v0.4.0` names,
  whose generated application signs people in through EHOS and preloads its fonts
