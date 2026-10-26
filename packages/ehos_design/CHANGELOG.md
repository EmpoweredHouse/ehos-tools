# Changelog

All notable changes to `ehos_design` are recorded here by hand, each in the pull request that
makes it, in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format. `ehos_design`
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a changed value is a patch, an
added token, component, class or state a minor version, and a removed or renamed one a major one,
whose line starts with `**Breaking:**`. Before 1.0.0, any minor version may break what the one
before it offered. Between releases the version is the next minor's `-dev`. A release's section is
the notes of its GitHub release, tagged `ehos_design-vX.Y.Z`
([releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)).

## [Unreleased]

### Added

- `EhosDesign.Mail`, the layout of a mailed message, moved here from EHOS (eh-os D-122) so that an
  application sending mail through EHOS uses the same one (#488): `html/1` and `text/1` render a
  message's HTML part and plain-text part from the same words. The body is a list of blocks given
  as data: `:paragraph`, `:rows` (an item with its detail), `:action` (a button with the link
  written out) and `:notice`; any other raises. The brand and its context, the label, the
  language and the footer are the sender's. The HTML is tables styled from the light theme's
  tokens, read from the package's own `colors_and_type.css` when it compiles and inlined by
  `premailex`, which the package now depends on, with Floki.

## [0.3.0] - 2026-10-20

### Added

- `ehos_design` is licensed under the Apache License 2.0, as the rest of ehos-tools
  ([LICENSE](https://github.com/EmpoweredHouse/ehos-tools/blob/main/LICENSE)); the fonts keep the
  SIL Open Font License 1.1.
- Each release is published on GitHub, tagged `ehos_design-vX.Y.Z`, with its section of this
  changelog as the notes and `release.json` beside it, which says its version and commit (eh-os
  D-91, [releases](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/releases.md)). It is
  never the release GitHub marks latest, which is `ehosctl`'s. `EhosDesign.release/1` is what it
  says.

- The outcome, a card that says how something ended: a mark (a lime check, or a coral cross for
  `data-kind="error"`), a title, one sentence and an optional hint, and `.eh-outcome-page` for a
  page that shows only that:
  - `priv/css/components/outcome.css`, its look as Claude Design has it (etag
    `1791579166454478`), recorded in `SOURCE.md` and imported by the layer in Tailwind's components
    layer;
  - `EhosDesign.Components.outcome/1`, which renders it.

  `ehosctl` shows the page the browser comes back to after `ehosctl login` with it.

- The badge, as the design system's "Badges + pills" card (`preview/21-badges.html`) draws it:
  mono, uppercase, a hairline border, `live` with a lime dot, `neutral` and `error`:
  - `.eh-badge`, `.eh-badge-live`, `.eh-badge-neutral`, `.eh-badge-error` and `.eh-badge-dot` in
    `ehos_design.css`, since the design system's source has no stylesheet for it;
  - `EhosDesign.Components.badge/1`, which renders it, with a host's classes beside its own.

  The rules sit in a layer nested in Tailwind's utilities one, so a page's utilities (`ml-2`,
  `px-3`, `text-xs`) still override them, on `.badge` too.

### Changed

- **Breaking:** a module that imports `EhosDesign.Components` beside a `badge/1` of the host's own
  no longer compiles where it calls `<.badge>`, since the call is then ambiguous: remove the
  host's own, or import the package's components with `except: [badge: 1]`.
- daisyUI's `.badge` looks like the design system's: `badge-success` is the live badge (without its
  dot), `badge-error` the error one, and every other colour and style the neutral one. The
  design system has one size, so `badge-xs` to `badge-xl` draw it too. `badge-success` was a
  solid fill of `--color-success`, an olive slab the design system never draws.
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
