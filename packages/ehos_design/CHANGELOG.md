# Changelog

All notable changes to `ehos_design` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehos_design` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): a changed value is a patch, an added
token a minor version, and a removed or renamed token a major one. Before 1.0.0, any minor version
may break what the one before it offered.

## [Unreleased]

## [0.1.0] - 2026-10-03

### Added

- The EmpoweredHouse design system as a package, moved from the EHOS console's copy
  ([eh-os D-72](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0072-the-design-system-is-a-library-ehos-design-kept-in-ehos-tools.md)):
  - `priv/css/colors_and_type.css`, the tokens as Claude Design had them on 2026-09-25 (etag
    `1781439475482903`), without the Google Fonts `@import`, and `priv/css/SOURCE.md`;
  - `priv/css/ehos_design.css`, the tokens mapped to Tailwind CSS 4 utilities and to one daisyUI 5
    theme, the fonts' `@font-face` rules, and daisyUI's buttons, inputs and checkboxes brought to
    the design system's rules;
  - Albert Sans and JetBrains Mono at 400 and 500, `latin` and `latin-ext`, in
    `priv/static/ehos_design/fonts/`, with their SIL Open Font License texts.
- Tests that the tokens and the fonts match the hashes in `SOURCE.md`, that nothing names another
  origin, that every token the layer uses is defined and none is redefined, and that every font it
  names is in the package.
