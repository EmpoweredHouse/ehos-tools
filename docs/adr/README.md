# Decision records

Why ehos-tools is the way it is, one decision per file, numbered `T-01`, `T-02`, … in the
[MADR](https://adr.github.io/madr/) format. Decisions about EHOS itself are EHOS's, numbered
`D-xx`, in [eh-os's `docs/adr/`](https://github.com/EmpoweredHouse/eh-os/tree/main/docs/adr), and
the choices made before these records began are in [`docs/research.md`](../research.md).

A record is written with the `write-adr` skill (`.claude/skills/write-adr/`). An accepted record
is never rewritten: a later one supersedes it.

| ID | Decision | Status |
| --- | --- | --- |
| [T-01](0001-ehos-tools-keeps-its-own-decision-records.md) | ehos-tools keeps its own decision records, numbered T-xx, beside EHOS's D-xx | accepted |
