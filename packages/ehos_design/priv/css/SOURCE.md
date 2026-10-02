# The EmpoweredHouse design system, as copied

`colors_and_type.css` is a copy of the design system's foundation, kept here so that nothing that
uses it needs Claude Design
([eh-os D-72](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0072-the-design-system-is-a-library-ehos-design-kept-in-ehos-tools.md)).
Do not edit it by hand: `test/ehos_design_test.exs` fails if it no longer matches the hash below. A
change reaches it only by a refresh, described in the package's [README](../../README.md#refreshing-the-tokens)
and, for Claude Code, in the `sync-design-system` skill of this repository.

| | |
| --- | --- |
| Project | EmpoweredHouse Design System [FINAL] (Claude Design, design-system project) |
| Project id | `3f8e8eea-af89-4d98-851c-760c2b2e862c` |
| File | `colors_and_type.css` |
| Etag in Claude Design | `1781439475482903` |
| Taken | 2026-09-25, by eh-os; moved here from there 2026-10-03 |
| SHA-256 as published | `fb98b275ea2e00182aa429268d9ea621ebcd96daa1ab8e48a235cc1ab17b7872` (16064 bytes, 416 lines) |
| Change made | The line `@import url("https://fonts.googleapis.com/css2?…")` is removed. The fonts are in this package, and the host serves them. |
| SHA-256 as committed | `704bbd4eecb0505700dd5531e8a4ead4b02c3fdc7e716e3aca24654a68e88888` |

## Fonts

Albert Sans and JetBrains Mono, weights 400 and 500, subsets `latin` and `latin-ext`, taken as WOFF2
from the npm packages `@fontsource/albert-sans@5.3.0` and `@fontsource/jetbrains-mono@5.3.0`. Both
are under the SIL Open Font License 1.1, whose text is beside the files in
`priv/static/ehos_design/fonts/`.

Each file as committed, so that a changed font shows in review and fails a test:

| File | SHA-256 |
| --- | --- |
| `albert-sans-latin-400-normal.woff2` | `59e53b4a6c96f13f12fa4db8fd163c4f7c5d304d8dc3f9eac6db7b67f429867f` |
| `albert-sans-latin-500-normal.woff2` | `88893bcdbef7b29342b539ac9a09f5de8cb15a442c2b8a2baaf97a70fb84fab8` |
| `albert-sans-latin-ext-400-normal.woff2` | `f1e24d19cf1d4be935f195e8b52612acabf287fa9b8c8327aa83541365e1d42d` |
| `albert-sans-latin-ext-500-normal.woff2` | `eb98afe51c5729e4e7b181ee83ccb2dd376595880c885d27e440d4d778b7e99f` |
| `jetbrains-mono-latin-400-normal.woff2` | `14425ba9c695763c1547f48a206b7aa60350a33ae23de09f0407877f3fcd89eb` |
| `jetbrains-mono-latin-500-normal.woff2` | `cb182feeed4d798ff6961d3c79f7026279448fca0676438aaecb21f3fc39553a` |
| `jetbrains-mono-latin-ext-400-normal.woff2` | `505dfba8ecbe77e82765f36d317ed7ef4ac42719dc5f4ae68d1c483fd22d0d14` |
| `jetbrains-mono-latin-ext-500-normal.woff2` | `879df9319f1cbf633bee1dd489e376a9e1e8c458f4abddcfe381cb83b5e6b027` |

## Not copied

- The marks of EmpoweredHouse, Shugyo and EHOS.
- The design system's README, brand book and claim system. Their visual rules are restated, for the
  EHOS console, in eh-os's `docs/DESIGN.md`; the copy and claims are not.
- The Shugyo screens, their data and screenshots.
