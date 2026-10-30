# Changelog

All notable changes to `ehos_diagrams` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that does starts with **Breaking:**.

## [Unreleased]

### Changed

- **Breaking:** the outputs' directory is refused when it is outside the current directory, named
  through `..`, or when it or a directory above it, below the current one, is a symbolic link, in
  a check as in a write: writing through such a link wrote outside the outputs. The refusal names
  the link ([#658](https://github.com/EmpoweredHouse/ehos-tools/issues/658)).

### Fixed

- A directory of sources whose path holds `--` is refused with a sentence, as any other refusal,
  instead of stopping with an `ArgumentError`: an output names its source in an XML comment, which
  cannot hold `--` ([#658](https://github.com/EmpoweredHouse/ehos-tools/issues/658)).
- A licence file beside the outputs that is a link, symbolic or hard, is no longer written through:
  it is refused, unless it is a file that already holds that licence. A link to a pipe or a
  device, as a licence or as an SVG file beside the outputs, is no longer read, which blocked
  ([#658](https://github.com/EmpoweredHouse/ehos-tools/issues/658)).

## [0.1.0] - 2026-10-30

### Added

- The generator of EHOS's diagrams, moved from eh-os's `Ehos.Dev.Diagrams` (eh-os D-107, T-21):
  `EhosDiagrams.render/5` checks a hand-laid SVG source and writes it in `ehos_design`'s colours
  and fonts, light and dark, against a vocabulary its host gives; `EhosDiagrams.Generator` does a
  directory of them, `EhosDiagrams.Pages` checks the pages that show them, and
  `mix ehos_diagrams.gen [--check]` does both from the host's `mix.exs`. eh-os's ten diagrams
  come out byte for byte as eh-os writes them
  ([#638](https://github.com/EmpoweredHouse/ehos-tools/issues/638)).
