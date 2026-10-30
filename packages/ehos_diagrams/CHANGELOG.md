# Changelog

All notable changes to `ehos_diagrams` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. The package follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0.0, any minor version may
break what the one before it offered, and a line that does starts with **Breaking:**.

## [Unreleased]

### Added

- The generator of EHOS's diagrams, moved from eh-os's `Ehos.Dev.Diagrams` (eh-os D-107, T-21):
  `EhosDiagrams.render/5` checks a hand-laid SVG source and writes it in `ehos_design`'s colours
  and fonts, light and dark, against a vocabulary its host gives; `EhosDiagrams.Generator` does a
  directory of them, `EhosDiagrams.Pages` checks the pages that show them, and
  `mix ehos_diagrams.gen [--check]` does both from the host's `mix.exs`. eh-os's ten diagrams
  come out byte for byte as eh-os writes them
  ([#638](https://github.com/EmpoweredHouse/ehos-tools/issues/638)).
