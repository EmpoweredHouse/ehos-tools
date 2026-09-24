# ehos-tools

The developer's side of EHOS: `ehosctl`, the command-line tool, and `ehos_app`, the template
it creates applications from.

| Path | What |
| --- | --- |
| `packages/ehosctl/` | the CLI, built into one self-contained binary per platform with Burrito |
| `packages/ehos_app/` | the template, as an Igniter installer (`mix ehos_app.install`) |
| `packaging/homebrew/` | a draft of the Homebrew formula, for a `homebrew-tap` repository |
| `docs/research.md` | why this stack: Burrito, Igniter, mise, a Homebrew tap |
| `docs/spike.md` | what was tried, what it measured, and what is still open |

Each package is its own Mix project and runs its own gate:

```sh
cd packages/ehos_app && mix check
cd packages/ehosctl && mix check
```

This is an early working version, built ahead of EHOS's roadmap on purpose: to try the
developer experience before Stage 6 (the application template) and Stage 7 (`ehosctl`)
define it. What it guesses about EHOS is listed in `docs/spike.md`.
