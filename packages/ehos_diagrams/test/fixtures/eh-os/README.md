# eh-os's diagrams

`EhosDiagrams.EhOsTest` renders these sources with this vocabulary. It proves that each output is
byte for byte the one eh-os committed (T-21). Everything here comes from eh-os at
[`706eb1ce`](https://github.com/EmpoweredHouse/eh-os/tree/706eb1ce), which pins `ehos_design` at
`cc5610b` (`ehos_design-v0.4.1`).

| File | From eh-os |
| --- | --- |
| `diagrams/*.svg` | `docs/architecture/diagrams/`, copied as they are |
| `img.sha256` | the SHA-256 of each file in `docs/architecture/img/`, as `shasum -a 256 *.svg` writes it. Hashes, not copies: each output embeds the fonts, about 85 KB |
| `vocabulary.json` | the vocabulary `Ehos.Dev.Diagrams.vocabulary/2` reads: `words`, the glossary words from `docs/architecture/glossary.md`, "The words"; `alone`, the words that list says a person never reads alone, with their phrases; `concepts`, each concept's badge in `docs/architecture/maturity.yml` |

The badges and their outlines are eh-os D-106's and D-107's, written in the test.

The test reads `ehos_design` from `packages/ehos_design` in this repository. Its tokens
(`priv/css/colors_and_type.css`) and fonts (`priv/static/ehos_design/fonts/`) are the same as at
`cc5610b`. If they change, the test fails, and it should: eh-os's diagrams would change with them
when eh-os takes that `ehos_design`.

Take them again from a later eh-os commit when eh-os changes a diagram or its vocabulary, and say
which commit here.
