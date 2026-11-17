---
status: proposed
date: 2026-11-17
decision-makers: []
consulted: []
---

# T-28 · `ehosctl` says everything in a few shared shapes, built as tagged data, and colours them only on a terminal without `NO_COLOR`

## Context and problem statement

`ehosctl` writes its results, progress, warnings and errors as prose. Each command builds its own
string, often one long line. The audit on [#979](https://github.com/EmpoweredHouse/ehos-tools/issues/979)
read every command and found the same problems everywhere:

- Several facts on one line (56 places), values buried in a sentence (44), and the next command
  hidden in the prose (37). The `install` success message has four or five facts and two
  commands in one paragraph. A GitHub Actions refusal is about 900 characters on one line.
- The same kind of message has different shapes (31 places). There are four date formats and four
  ways to show an empty value. A warning appears as an error (`ehosctl: …`), as progress
  (`==> Warning: …`), as plain stdout or with no prefix. `verify` and the `deploy` wait print
  progress on stdout. `logs --follow` exits 0 but prints `ehosctl: …`.
- Long steps are silent for up to 10 minutes (`tofu apply`, `helm --wait`), and one wait prints the
  same line 30 times.

[T-06](0006-ehosctl-reads-its-command-line-with-optimus-and-writes-to-the-terminal-with-owl.md)
chose Owl to write for a person, so that tables, prompts and progress "look the same from command
to command". Only the tables did this (`Ehosctl.Output.table/2`, about 25 listings). Everything else
is a string. A string cannot be coloured safely either: `Ehosctl.Output.shown_lines/1` escapes
every control character, because a line can hold what a server or another tool wrote
([#165](https://github.com/EmpoweredHouse/ehos-tools/issues/165)), and an ANSI code is a control
character.

Most of what `server *`, `install` and `upgrade` say is written in `ehos_platform`
(`EhosPlatform.Server`, `EhosPlatform.Install`), which returns finished sentences and calls a
`progress: (String.t() -> any())` function. `ehosctl` is the only program that prints them; eh-os
does not depend on `ehos_platform`.

This must be decided before the commands are changed one by one (step 4 of #979). After that, a
different choice means changing every command a second time.

## Decision drivers

1. **Scripts see nothing new.** `--json`, exit codes, and output into a pipe or a file stay as they
   are (T-06, `Ehosctl.Output`'s exit-code contract).
2. **What a server or a tool wrote never reaches the terminal unescaped** (#165), including when
   colour is on.
3. **A person finds the outcome, the values and the next command without reading a paragraph.**
4. **One shape for each kind of message**, so that a new command cannot use a different shape.
5. **Tests stay readable and do not depend on a terminal**. The present text assertions change
   only where the words change.
6. **A standard library and a standard convention over our own** (`AGENTS.md`): Owl, which is
   already a dependency, and the `NO_COLOR` convention.

## Considered options

1. **Shared shapes, built as Owl tagged data, rendered once in `Ehosctl.Output`; colour only when
   the device is a terminal and `NO_COLOR` is not set**
2. **Colour added to the present strings**, with ANSI codes inserted where each command builds its
   text
3. **Only better strings**: the same shapes written by hand in each command (line breaks, aligned
   labels, a `Next:` line), with no data type and no colour
4. **A full terminal UI** for long commands: Owl's live screen, spinners and progress bars that
   redraw lines

## Decision outcome

Chosen option: **"Shared shapes, built as Owl tagged data, rendered once in `Ehosctl.Output`"**,
because it is the only option that gives every command the same shapes (driver 4) and colour
without unescaped server text reaching the terminal (driver 2). It keeps pipes and `--json` as
they are (driver 1) and uses Owl as T-06 intended (driver 6).

**The shapes.** `Ehosctl.Output` gets one function for each shape. A command builds its text only
from these:

| Shape | What it looks like | Colour on a terminal |
| --- | --- | --- |
| Outcome | One short sentence with a marker: `✓` done, `✗` failed, `!` warning, `·` nothing changed | the marker: green, red, yellow, dim |
| Labelled values | Aligned `label   value` lines under the outcome: an address, an id, a fingerprint, a path, an expiry | the label dim, the value bold |
| Next | `Next:`, then each command on its own indented line, ready to copy, with the `--installation` that was given | the command cyan |
| Warning | On stderr: `! ` and one short head line, then the explanation indented under it | `!` and the head line yellow |
| Error | On stderr: `ehosctl: ` and what failed on the first line, then `What to do:` and the command | `ehosctl:` red |
| Progress | On stderr: `==> ` and the step. A long step shows a sign of life (elapsed time, or one line for each change of state), and each step ends with a closing line | `==>` dim |
| Tool output | What `tofu`, `helm`, `kubectl`, `ssh`, `mix` or `git` printed, under a header that names the tool, each line indented | dim |
| List | A table (`Output.table/2`, as today) or an indented `- ` list. Never a comma list in a sentence when there can be more than two items | none |

Values have one form everywhere: dates through `Output.date/1`, and one form for an empty value.
The words in each shape follow the `ehos-dev:voice` skill, as they do today.

**Building and rendering.** A command's `text:` becomes Owl data (`Owl.Data.t()`: strings and
`Owl.Data.tag/2`), built by the shape functions. A plain string stays valid, so commands move one at
a time. `Output.result/2` and `Output.error/3` render it in three steps:

1. Every string leaf goes through `shown_lines/1` first, so what a server or a tool wrote is
   escaped before any ANSI code exists.
2. If colour is on for that device, `Owl.Data.to_chardata/1` turns the tags into ANSI codes.
   Otherwise `Owl.Data.untag/1` removes them.
3. The result is printed.

**When colour is on.** For each device separately (stdout, stderr): only when the device is a
terminal (`:prim_tty.isatty/1`, Erlang/OTP 26 and later), and `NO_COLOR` is not set to a non-empty
value (<https://no-color.org>). Never under `--json`. `ehosctl` decides this itself and passes the
decision to the renderer as data. It does not set `:elixir, :ansi_enabled` (eh-os D-160: no
setting is changed to choose a behaviour). The markers (`✓`, `!`, `==>`) do not depend on colour,
so the shapes read the same in a pipe, in a log and in a test.

**`ehos_platform`** returns the parts and not the sentence: the outcome, the labelled values, the
next commands, the warnings, and progress as events (`{:step, text}`, `{:waiting, text, elapsed}`,
`{:warning, text}`, `{:tool_output, tool, text}`), as data that its own module defines. It does not
depend on Owl or on `ehosctl`. `ehosctl` maps this data to the shapes. A test of `ehos_platform`
asserts on the data and not on a rendered sentence.

**What this amends in T-06.** T-06 says errors on stderr are "plain `IO`, so a script never sees a
colour code". This holds: an error and a warning get colour only when stderr is a terminal, which a
script that reads stderr is not.

### Consequences

- Good, because the outcome, the values and the next command are on lines of their own, and the
  same in every command.
- Good, because a fix in a shared path (did not answer, TLS, not signed in, choosing an
  installation, progress) changes all the commands that use it. The audit lists these paths on
  #979.
- Good, because escaping comes before colour in one place, so #165's protection does not depend on
  each command doing it correctly.
- Good, because the present tests run without a terminal and so get no colour. Only the tests of
  messages whose words or layout change are changed, and they change with that message.
- Bad, because about 80 places in `ehosctl` and the result and progress functions of
  `ehos_platform` change. Mitigation: a plain string stays valid, so the change goes one group of
  commands at a time, in the order the audit gives.
- Bad, because the shapes use more lines than a sentence. A short result (`Signed out of office.`)
  stays one outcome line with no labelled values.
- Bad, because `ehos_platform`'s public functions change their return values, which is a breaking
  change for that package. Mitigation: `ehosctl` is its only consumer, and both are released from
  this repository.
- Bad, because `:prim_tty.isatty/1` is not a documented API of Erlang. Mitigation: it is wrapped
  in one function in `Ehosctl.Output`, and if it is missing, the function falls back to
  `:io.columns/1`, which returns an error when the device is not a terminal.
- Neutral: Windows terminals that do not show ANSI are not a target. The binaries are for macOS and
  Linux.

### Confirmation

- `Ehosctl.OutputTest` asserts that for each shape:
  - with colour off, the output has no ESC character;
  - with colour on, a string that holds `\e[2J` is printed escaped, and the ANSI codes appear
    only around the tags;
  - `NO_COLOR` turns colour off;
  - `--json` never has colour.
- A test in the style of `Ehosctl.ConventionsTest` fails when a command module calls
  `IO.puts`/`IO.write` directly, outside `Ehosctl.Output` and the prompts. The audit found
  progress printed to stdout, and a success printed as `ehosctl: …`.
- A test fails when a table cell or a line holds a raw ISO 8601 date where `Output.date/1` is the
  rule.
- `EhosPlatform.ServerTest` and `EhosPlatform.InstallTest` assert on the returned parts and on the
  progress events, not on sentences.

## Pros and cons of the options

### Shared shapes, built as tagged data

- Good, because the shapes are code, so a command cannot drift from them, and colour is a property
  of the renderer and not of each command.
- Good, because Owl already does the work: `Owl.Data.tag/2` and `untag/1`, and its
  `to_chardata/1` ends in `IO.ANSI.format/1` (Owl 0.13.1, `lib/owl/data.ex`).
- Bad, because `text:` changes type, from a string to Owl data, and `ehos_platform` changes its
  API.

### Colour added to the present strings

- Good, because it is the smallest change: a few `IO.ANSI` calls in each command.
- Bad, because `shown_lines/1` escapes the codes. To keep them, the escaping must move into each
  command, around each value that a server sent. One missed value breaks #165.
- Bad, because a long line in colour is still a long line. It does not fix the 56 lines with
  several facts or the 37 hidden commands.

### Only better strings

- Good, because there is no new type and no colour to test, and the readability problems are fixed.
- Bad, because each command writes the shapes by hand, so they drift, as the four date formats and
  the four empty values show.
- Bad, because adding colour later means changing every command again.

### A full terminal UI

- Good, because a spinner or a progress bar makes a long step visibly alive.
- Bad, because a redrawn line is lost in a log, in CI and in a pipe. T-06 already keeps it out of
  `--json` and stderr for this reason.
- Bad, because most of the problem is the result and the errors, not the waiting. Progress events
  with elapsed time cover the waits without redrawing.

## More information

- Decided under [#979](https://github.com/EmpoweredHouse/ehos-tools/issues/979), whose audit
  comment has the counts, the examples and the order of the work.
- Related: [#508](https://github.com/EmpoweredHouse/ehos-tools/issues/508) (`ehosctl verify` hides
  its gates among Mix's `==>` lines), which the Tool output and Progress shapes cover.
- `NO_COLOR`: <https://no-color.org>. Owl: <https://hexdocs.pm/owl/0.13.1/Owl.Data.html>.
- Revisit if a later Owl release changes how it renders tags, or if `ehosctl` gets a Windows target.
