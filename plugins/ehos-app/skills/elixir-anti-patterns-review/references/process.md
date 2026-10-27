<!--
  SPDX-License-Identifier: Apache-2.0
  SPDX-FileCopyrightText: 2021 The Elixir Team
  Modified: condensed and adapted for the Shugyo backend, then for EHOS applications.
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
If a worker refetches by ID, preserve the intended revision; reducing the
payload must not change which data the operation uses.

## Unsupervised processes and failure handling

Background work uses supervisors rather than bare `spawn` or `Task.async`. When a caller
must handle a task crash, use `Task.Supervisor.async_nolink` and consume its exit result; a linked
task may kill that caller before its error branch executes. Establish who owns cancellation,
timeouts, and termination.

At external boundaries, exception/exit handling must record a terminal reason, and cleanup in
`after` must not raise over it. Deadlines bound provider calls; a supervision tree alone does not
settle a persisted `:running` record.

## Oban scope and delivery

Oban's tables live in the schema EHOS gives the application (`prefix:`, from `DATABASE_SCHEMA`).
The contract engine runs an effect, and a reaction delivered `:at_least_once`, as an Oban job
inserted in the dispatch transaction: a second delivery must be harmless, and the contract names
what makes it so.

Trace atomic enqueue, uniqueness conflicts, retry idempotency, and cancellation against persisted
domain state. Queue retries/recovery do not prove that external work completed. Use the actual
checkout's engine, workers, and recovery helpers; do not introduce Oban Pro APIs as a generic fix.

For process tests, check sandbox ownership and that mocks reach the processes that call them:
where the cases have `setup_mocks/1`, it calls Hammox's `set_mox_from_context`, private in an
`async` test and global in one that is not, and a process the test did not start as a caller (a
supervised GenServer) needs `allow/3` (`ehos-app:elixir`,
[tests](../../elixir/references/testing.md)). A test that swaps an implementation with
`Application.put_env/3` is a finding where the application has Hammox, not a reason to be
non-async; one that dispatches or spawns DB work needs the documented non-async setup, and pure
tests may be async. Synchronize on observable completion, not fixed sleeps.
