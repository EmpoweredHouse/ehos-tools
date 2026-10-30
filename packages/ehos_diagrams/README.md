# ehos_diagrams

The generator for the diagrams in EHOS's documentation. A diagram is an SVG source laid out by
hand. The generator checks the source and writes it again as an SVG file in `ehos_design`'s colours
and fonts, light and dark
([eh-os D-107](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0107-architecture-diagrams-are-svg-files-generated-by-mix-from-hand-laid-sources-and-skinned-by-ehos-design.md)).
eh-os wrote it for its architecture. It is shared from here so that every EHOS repository draws
diagrams the same way
([T-21](https://github.com/EmpoweredHouse/ehos-tools/blob/main/docs/adr/0021-eh-os-s-diagram-generator-is-shared-as-ehos-diagrams-a-package-here-that-takes-its-vocabulary-and-ehos-design-from-its-host.md)).

How to draw a diagram, from the question it answers to the source, is the `ehos-dev:diagrams`
skill ([`plugins/ehos-dev/skills/diagrams/`](https://github.com/EmpoweredHouse/ehos-tools/blob/main/plugins/ehos-dev/skills/diagrams/SKILL.md)).

## What it does

| Module | For |
| --- | --- |
| `EhosDiagrams` | One source: `render/5` checks it and writes the output, or names each thing the source breaks. A source is data, never code: it is refused before it is parsed when it is not UTF-8, has a DTD or a processing instruction, and after it when it holds an element, attribute, class or reference outside the allow-lists, a connector that is not orthogonal, a label without a mask, more than the budget, or a label outside the vocabulary. |
| `EhosDiagrams.Generator` | A directory of sources, written into a directory of outputs with the fonts' licences beside them; the outputs that are stale and those with no source. `run/3` is what `mix ehos_diagrams.gen` does. |
| `EhosDiagrams.Pages` | The pages: an image a page links that does not exist, an output no page links, and a Mermaid block. |
| `mix ehos_diagrams.gen [--check]` | All of it for a host, from its `mix.exs`. |

The output is byte for byte the same on macOS and Linux, so `--check` in CI fails only on a real
difference.

## What the host gives

- **Its vocabulary** (`t:EhosDiagrams.vocabulary/0`): the glossary words, the words never shown
  alone with the phrases they may appear in, the concepts with their badges, and the badges with
  their outlines. A host with no maturity gives no concepts and no badges.
- **`ehos_design`**, as its own dependency. The generator reads the tokens and fonts of the
  `ehos_design` the host has, so a host's diagrams change with the `ehos_design` it pins.
- **Its paths**: where the sources, the outputs, the pages and the documents are.

## Depending on it

It is released by tags, `ehos_diagrams-vX.Y.Z`, each with a GitHub release. Its `CHANGELOG.md`
says what each one changed. It is not on Hex: a project depends on the commit a tag names, from
this repository's subdirectory, in `:dev` and `:test` only.

```elixir
{:ehos_diagrams,
 github: "EmpoweredHouse/ehos-tools",
 sparse: "packages/ehos_diagrams",
 ref: "<the commit ehos_diagrams-vX.Y.Z names>",
 only: [:dev, :test],
 runtime: false}
```

Then, in the host's `project/0`:

```elixir
ehos_diagrams: [
  sources: "docs/diagrams",
  out: "docs/img",
  vocabulary: {MyProject.Docs, :vocabulary, []},
  pages: ["README.md", "docs/**/*.md"],
  documents: ["docs/**/*.md"]
]
```

Run `mix ehos_diagrams.gen` to write the outputs, and `mix ehos_diagrams.gen --check` in the
host's gate.

## Developing it

`mix check` is the gate (`CONTRIBUTING.md`, "The gate"). The tests read `ehos_design` from
`packages/ehos_design`. `EhosDiagrams.EhOsTest` renders eh-os's ten diagrams and compares them with
the outputs eh-os committed; `test/fixtures/eh-os/README.md` says where they come from.
