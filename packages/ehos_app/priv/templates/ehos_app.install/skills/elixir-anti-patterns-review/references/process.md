<!--
  SPDX-License-Identifier: Apache-2.0
  SPDX-FileCopyrightText: 2021 The Elixir Team
  Modified: condensed and adapted for the Shugyo backend.
-->

# Process patterns

## Code organization by process

A module doing pure calculations does not need a GenServer. Propose functions when the process
adds serialization or a lifecycle without owning state. GenServers, Agents, ETS owners, and
supervisors are justified when they manage shared state, resource ownership, or coordination;
identify the actual contention or unnecessary behavior before suggesting removal.

## Scattered process interfaces

Prefer an owning module's API over callers sending ad hoc messages that depend on internal state.
Before adding a wrapper, check existing handlers and behaviours. OTP callbacks and an established
message protocol are not violations just because several callers use them.

## Sending unnecessary data

Extract the needed value before creating a closure; extracting inside it still captures the struct:

```elixir
# Captures all of conn, including its request data.
Task.Supervisor.start_child(Api.ChatTaskSupervisor, fn -> report_ip(conn.remote_ip) end)

# Captures only the address.
remote_ip = conn.remote_ip
Task.Supervisor.start_child(Api.ChatTaskSupervisor, fn -> report_ip(remote_ip) end)
```

The snippet illustrates capture size only; the caller must also handle task-start failure.
Don't send connections, sockets, credentials, or large preloaded graphs when IDs/scalars suffice.
If a worker refetches by ID, preserve organization scope and the intended revision; reducing the
payload must not change which data the operation uses.

## Unsupervised processes and failure handling

Backend background work uses supervisors rather than bare `spawn` or `Task.async`. When a caller
must handle a task crash, use `Task.Supervisor.async_nolink` and consume its exit result; a linked
task may kill that caller before its error branch executes. Establish who owns cancellation,
timeouts, and termination. The current Docker runner is a useful example:
`apps/backend/apps/wiki/lib/wiki/agent_runner/docker.ex`.

At external runner boundaries, exception/exit handling must record a terminal reason, and cleanup
in `after` must not raise over it. Deadlines bound provider and container calls; a supervision tree
alone does not settle a persisted `:running` record. For chat turns, reuse the streaming driver
and task registry instead of creating another lifecycle.

## Oban scope and delivery

One public job queue is intentional. Tenant jobs carry `organization_id`, resolve the active ready
business prefix through the existing scope helper, and include organization identity in uniqueness
and direct job queries. `conf.prefix` is job storage, not the business prefix.

Trace atomic enqueue, uniqueness conflicts, retry idempotency, and cancellation against persisted
domain state. Queue retries/recovery do not prove that external work completed. Use the actual
checkout's engine, workers, and recovery helpers; do not introduce Oban Pro APIs as a generic fix.

For process tests, check sandbox ownership and Mox permissions using `TESTING.md`. Tests changing
application configuration, using shared tenant fixtures, or spawning DB work need the documented
non-async setup; pure tests may be async. Synchronize on observable completion, not fixed sleeps.
