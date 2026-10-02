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

## Not copied

- The marks of EmpoweredHouse, Shugyo and EHOS.
- The design system's README, brand book and claim system. Their visual rules are restated, for the
  EHOS console, in eh-os's `docs/DESIGN.md`; the copy and claims are not.
- The Shugyo screens, their data and screenshots.
