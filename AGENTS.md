# ehos-tools

`ehosctl` and the `ehos_app` template for EHOS. Read `README.md` for the layout, and
`docs/spike.md` before changing anything: it records what was measured and what is still open.

## Rules

- Everything is in English: code, comments, docs, commit messages.
- The specification of EHOS lives in `~/Projects/ai/eh-os` (`docs/ARCHITECTURE.md`,
  `docs/ROADMAP.md`, `docs/adr/`). Read it; do not write to it from here. Where this repository
  has to guess what EHOS will require, say so in `docs/spike.md`.
- Prefer a standard, community-proven library or tool to writing one; say why when you don't.
- Mix is the only entry point: aliases and Mix tasks. No Makefile, no shell scripts.
- Each package builds and tests on its own. Run its `mix check` before committing, and check a
  command's own exit code, not the exit code of a pipe.
- The installer is idempotent: a second `mix ehos_app.install` changes nothing, and a test pins it.
- What `ehosctl` pins (toolchain, archives, installer) lives in `lib/ehosctl/template.ex` and
  nowhere else.
