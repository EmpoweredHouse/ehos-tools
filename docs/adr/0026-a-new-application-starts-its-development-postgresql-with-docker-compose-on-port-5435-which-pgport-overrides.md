---
status: accepted
date: 2026-11-11
decision-makers: [Emil Wojtaszek]
consulted: [eh-os D-27]
---

# T-26 · A new application starts its development PostgreSQL with Docker Compose, on port 5435, which `PGPORT` overrides

## Context and problem statement

An application that `ehos_app` generates connects in development and in tests to a PostgreSQL on
`localhost:5432`, with the user and password `postgres`, as `phx.new` writes `config/dev.exs` and
`config/test.exs`. Nothing in the project starts that PostgreSQL, and the generated docs do not say
how to get one. A developer without it stops at the first `mix setup`
([#885](https://github.com/EmpoweredHouse/ehos-tools/issues/885)). CI does not show the gap: its
workflow starts a PostgreSQL of its own with `ikalnytskyi/action-setup-postgres`.

eh-os already solved this for itself
([D-27](https://github.com/EmpoweredHouse/eh-os/blob/main/docs/adr/0027-local-toolchain-and-cluster.md)):
a `docker-compose.yml` with PostgreSQL on a port of its own, which `mix setup` starts. The
decision here is what the template writes into an application, which is the developer's code
once written.

## Decision drivers

1. A developer on a clean computer goes from `mix setup` to `mix phx.server` and `mix test` with
   the generated guide alone.
2. The project does not meet a PostgreSQL the developer already has on 5432, nor eh-os's (5434)
   or eh-os-contract's (5433).
3. A developer who prefers a PostgreSQL of their own can use it without editing the project.
4. A project from an earlier version keeps its configuration; a second run of the installer
   changes nothing; CI keeps working for both.
5. A standard, community-proven tool, entered through Mix (no Makefile, no shell script).

## Considered options

1. **Docker Compose, on a port of its own, which `PGPORT` overrides**: the template writes
   `compose.yaml` with PostgreSQL at the major version EHOS runs, `config/dev.exs` and
   `config/test.exs` read the port from `PGPORT` (5435 unless set), and `mix setup` runs
   `docker compose up --detach --wait` before `ecto.setup`.
2. **Docker Compose on 5432**: the same, on PostgreSQL's own port, with no change to the
   configuration.
3. **Docs alone**: the guide says to install PostgreSQL on 5432 with the user `postgres`, and the
   template starts nothing.
4. **A `DATABASE_URL` in development**: the configuration reads one URL, and the developer brings
   the server.

## Decision outcome

Chosen option: **1, Docker Compose on a port of its own, which `PGPORT` overrides**, because it
is what eh-os does, it meets none of the developer's other servers, and `PGPORT` is libpq's own
variable, so `psql -h localhost` and the application read the same port.

- **`compose.yaml`** (the Compose specification's name) runs `postgres:18-alpine`, the major
  version EHOS's installations run, by its tag rather than a digest: the file is the developer's
  once written and the installer never rewrites it, so a digest would hold each project at the
  patch it was generated with. It has the user and password `postgres`, a named volume, and a
  health check over TCP, so `--wait` returns once it accepts connections. The host port is
  `${PGPORT:-5435}`, on `127.0.0.1` alone, so the well-known password is not reachable from the
  network.
- **The configuration** gives the repo `port: String.to_integer(System.get_env("PGPORT", "5435"))`
  in `config/dev.exs` and `config/test.exs`.
- **`mix setup`** runs `cmd docker compose up --detach --wait` after `deps.get` and before
  `ecto.setup`. With no Docker, it stops there with Docker's message, and the guide says what to do.
- **A PostgreSQL of the developer's own**: export `PGPORT` with its port, and run the steps of
  `mix setup` after the one that starts Compose.
- **Only a new project** (Phoenix's untouched one, with no Compose file) gets the three changes. A
  project that already has `ehos.yaml`, a Phoenix project with its own home page, or one with a
  Compose file of its own keeps its configuration and its aliases; its guide keeps saying
  PostgreSQL on 5432.
- **CI** keeps the action's PostgreSQL on 5432 and sets `PGPORT: "5432"` for the job. A new
  project's configuration reads it; an older one's sets no port, so Postgrex reads the same
  variable.

### Consequences

- Good, because `mix setup` on a computer with Docker is the only step, as the issue asked.
- Good, because one variable moves the port for Compose, the application and `psql -h localhost`
  at once, so two applications run side by side with `PGPORT` set for the second.
- Bad, because a developer needs Docker (or a compatible engine). Mitigation: the guide names the
  way without it.
- Bad, because a `PGPORT` exported for another purpose also moves this project's server, and
  Compose fails when that port is taken. Mitigation: the guide says the server runs on the port
  `PGPORT` names, and Docker's message names the port in use.
- Bad, because the container does not start again after the computer restarts. Mitigation: the
  guide says that `docker compose up --detach --wait` starts it.
- Neutral: older projects get none of it; their developer can copy the three changes from a new
  project.

### Confirmation

- The installer's tests: a new project gets `compose.yaml`, the port in both configurations and
  the step in `setup`; a project with `ehos.yaml` gets none; a second run changes nothing (the
  idempotency test); the harness budget holds the guide.
- The `e2e` job, which sets `PGPORT` as the template's workflow does.
- A project generated from the branch, run from `mix setup` to `mix test` against Compose's
  PostgreSQL.

## Pros and cons of the options

### Option 1: Docker Compose, on a port of its own, which `PGPORT` overrides

- Good, because it meets no other server and needs no edit to opt out.
- Bad, because the configuration reads an environment variable in development, which Phoenix's
  default does not.

### Option 2: Docker Compose on 5432

- Good, because the configuration stays Phoenix's.
- Bad, because it fails on every computer that already runs a PostgreSQL, the case #885 found.

### Option 3: Docs alone

- Good, because the template writes nothing new.
- Bad, because the developer installs and configures a server by hand, and the user and password
  `postgres` on 5432 is not what most installations give.

### Option 4: A `DATABASE_URL` in development

- Good, because it is one variable for any server.
- Bad, because it starts nothing, so the clean computer still stops at `mix setup`, and a test
  database per partition needs the name built from the URL.

## More information

Decided under [#885](https://github.com/EmpoweredHouse/ehos-tools/issues/885).

Revisit when EHOS's installations move to a later major version of PostgreSQL (the image's tag
follows it), or when EHOS gives developers a database of its own to develop against.
