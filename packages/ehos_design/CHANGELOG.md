# Changelog

All notable changes to `ehos_design` are recorded here, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehos_design` follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): a changed value is a patch, an added
token, component, class or state a minor version, and a removed or renamed one a major one. Before 1.0.0, any minor version
may break what the one before it offered.

## [Unreleased]

### Added

- The outcome, a card that says how something ended: a mark (a lime check, or a coral cross for
  `data-kind="error"`), a title, one sentence and an optional hint, and `.eh-outcome-page` for a
  page that shows only that:
  - `priv/css/components/outcome.css`, its look as Claude Design has it (etag
    `1791579166454478`), recorded in `SOURCE.md` and imported by the layer in Tailwind's components
    layer;
  - `EhosDesign.Components.outcome/1`, which renders it.

  `ehosctl` shows the page the browser comes back to after `ehosctl login` with it.

### Changed

- The README's "A look of your own" also says to remove the `@source` of the package's templates
  and the import of its hooks and `...designHooks` in `assets/js/app.js`.

## [0.2.0] - 2026-10-08

### Added

- The listbox, the design system's first application component
  ([eh-os D-86](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0086-the-design-system-s-source-holds-component-stylesheets-and-ehos-design-ships-the-components-built-on-them.md)):
  - `priv/css/components/listbox.css`, its look as Claude Design has it (etag `1791492415436111`),
    recorded in `SOURCE.md` and imported by the layer in Tailwind's components layer;
  - `EhosDesign.Components.picker/1`, a button that opens a list to choose from, and
    `combobox/1`, a text field whose list shows what the application found, both after the
    WAI-ARIA combobox patterns, with one colocated hook for the arrow keys, Home and End, Enter,
    Escape and `aria-activedescendant`;
  - a browser test of the keyboard with Playwright, set up with `mix browser.setup`.

- The README says how to preload the two faces of Albert Sans text is set in, and why only those
  ([#10](https://github.com/EmpoweredHouse/ehos-tools/issues/10)).

### Changed

- The package depends on Phoenix LiveView 1.1 or later, and runs its compiler, which writes the
  hook's manifest under `phoenix-colocated/ehos_design`.
- The README's "Refreshing the tokens" is "Refreshing the design system", and covers the
  components' stylesheets.

- The README pins the package to the commit a release's tag names, with the release's version as
  its requirement, as `ehos_app` does; it said to take it at the tag, which can be moved
  ([#23](https://github.com/EmpoweredHouse/ehos-tools/issues/23)).

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
