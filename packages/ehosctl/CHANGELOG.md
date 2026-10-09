# Changelog

All notable changes to `ehosctl` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehosctl` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered.

A release pins one template (`lib/ehosctl/template.ex`), so every change to a pin is listed here:
it changes what `ehosctl init` generates.

## [Unreleased]

### Added

- `ehosctl login [URL]`, `ehosctl whoami` and `ehosctl logout` (eh-os D-89). `login` signs you
  in through your browser, as EHOS's public client `ehosctl`: the code flow with PKCE and a
  redirect to `127.0.0.1` (T-09). It adds or updates the installation and makes it current.
  `whoami` says who you are, where, and until when. `logout` revokes the sign-in at EHOS and
  forgets it here, even when EHOS does not answer.
- The sign-in's refresh token is kept in the system's keychain (macOS's Keychain, or the Secret
  Service through `secret-tool`), or else in a file only you can read, with a warning. Ten-minute
  credentials are cached beside it, and one renewal runs at a time, under a lock (T-08).
  `EHOSCTL_TOKEN_STORE=file` chooses the file, and `EHOSCTL_STATE_DIR` moves the state directory.
- `ehosctl installations list | use NAME | remove NAME`: the installations of EHOS you know, under
  names you give them, one of them current, kept in `~/.config/ehosctl/config.json` (T-07). A
  governed command talks to the one `--installation`, `EHOSCTL_INSTALLATION` or the current one
  names.
- `--json` on the commands that can answer in JSON, and stable exit codes per kind of error:
  1 failed, 2 invalid, 3 refused, 4 not signed in, 5 unreachable.
- Every command's help names its plane: governed, platform or local (eh-os D-87).
- The reference documentation, built by `mix docs`.

### Changed

- The command line is read with Optimus (T-06): the help has a new layout, and
  `ehosctl help init`, `ehosctl init -h` and `ehosctl init shop --help` work as
  `ehosctl init --help` does. An unknown command or option now exits with 2, not 1, and so does
  `ehosctl init` with no name or with more than one, or with a name that starts with a dash,
  which is read as an option. A name `init` refuses still exits with 1.

### Fixed

- `ehosctl init` generates under the pinned Erlang and Elixir when another version manager's
  shims (asdf's) come before mise's on the `PATH`. It generated under that manager's versions
  instead, and wrote them into the project's `.tool-versions` and Dockerfile, without a word:
  `mise install` and each Mix step now run with `MISE_ACTIVATE_AGGRESSIVE=1`
  ([#64](https://github.com/EmpoweredHouse/ehos-tools/issues/64)).

## [0.2.0] - 2026-10-09

`ehosctl init` creates applications from `ehos_app` 0.6.0 at `9c97894`, in place of 0.5.0 at
`9f3cfd2`.

### Changed

- The template is `ehos_app` 0.6.0. A new application:
  - takes `ehos_design` 0.2.0, with the design system's listbox, `EhosDesign.Components.picker/1`
    and `combobox/1`, and its hooks in the LiveSocket
    ([eh-os D-86](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0086-the-design-system-s-source-holds-component-stylesheets-and-ehos-design-ships-the-components-built-on-them.md));
  - compiles against eh-os-contract's `main`, whose contracts name their id, as `ehos_app` 0.5.1
    made its example contract do.

## [0.1.2] - 2026-10-06

`ehosctl --help` says which template a binary creates applications from. The template is the
same as 0.1.1's, `ehos_app` 0.5.0 at `9f3cfd2`, so what `init` generates is unchanged.

### Added

- `ehosctl --help`, and `ehosctl` alone, print the version and what `init` creates an
  application from: `ehos_app`'s version and commit, Erlang, Elixir, `phx_new` and
  `igniter_new`, and that `eh_os_contract` follows eh-os-contract's `main`. When
  `EHOSCTL_TEMPLATE_SOURCE` replaces the pinned template it says so, and when it holds a value
  `init` refuses it says that instead. `ehosctl --version` still prints the version alone, as CI
  compares it with the tag.

### Fixed

- The READMEs say what to do when `mise use -g` has installed `ehosctl` and the shell does not
  find it: mise is not active in a shell that uses asdf, so its shims go at the end of the `PATH`.
  The root README gives the line for zsh, bash and fish.

## [0.1.1] - 2026-10-06

`ehosctl init` creates an application from `ehos_app` 0.5.0, whose contract engine follows
eh-os-contract's `main` and whose sign-in sits on the root layout. `mise upgrade ehosctl`, or
`mise use -g github:EmpoweredHouse/ehos-tools@0.1.1`, takes it; a project already created moves to
0.5.0 as `ehos_app`'s CHANGELOG says.

### Changed

- The template is `packages/ehos_app` of ehos-tools at `9f3cfd2`, the commit the tag
  `ehos_app-v0.5.0` names, with `"== 0.5.0"` as its requirement, in place of 0.4.0's `9ba6f3e`.
  A new project takes `eh_os_contract` and `eh_os_contract_auth` from eh-os-contract's `main`,
  so two projects created by this release on different days can have different commits of them
  in `mix.lock`
  ([T-05](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md)).

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
  ([T-05](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0005-a-generated-project-follows-eh-os-contract-main-while-it-tags-no-release.md)).

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
