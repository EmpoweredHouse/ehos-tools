<!--
  SPDX-License-Identifier: Apache-2.0
  SPDX-FileCopyrightText: 2021 The Elixir Team
  Modified: condensed and adapted for the Shugyo backend, then for EHOS applications, then for
  EHOS's own libraries, CLI and platform.
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
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> report_ip(conn.remote_ip) end)

# Captures only the address.
remote_ip = conn.remote_ip
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> report_ip(remote_ip) end)
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
`after` must not raise over it. Deadlines bound calls to outside systems; a supervision tree alone
does not settle a persisted `:running` record.

## Settings and collaborators of a supervised process

A process the application starts cannot be reached by a test's mock or setting. Check that it
takes its settings, its collaborators and its name as start options, each defaulting to its
production value (`ehos-dev:elixir`, [structure.md](../../elixir/references/structure.md)), in code
the repository's rules cover. Flag one that reads a setting from `Application` env at each
message for a test's sake, one switched off by an `enabled:` flag it checks itself, a test that
sets what the first call needs only after `start_supervised!/1`, and a test that reaches a process
the application started without `allow/3` or global mode.

## Programs and Ports

A program runs through the repository's runner behaviour, from its executable and a list of
arguments, never a shell string (`sh -c`, `:os.cmd/1`). Check that its exit status is read, that a
long run has a timeout or is told to stop, and that what it prints is read in full or streamed,
not left to fill a pipe. A `Port` is owned by one process, which closes it; a CLI that hands the
terminal to a program says so, as `Ehosctl.Runner`'s `interactive/3` does with
`:nouse_stdio`.

## Process tests

Check that the mocks reach the processes that call them, as `ehos-dev:elixir` says
([structure.md](../../elixir/references/structure.md), "A supervised process takes its values when
it starts"): a `Task` carries `$callers`, a process under the test's `start_supervised!/1` is
reached through its parent, and any other needs `allow/3`. A test that needs a
process the application starts stays `async: false` and says why; pure tests may be async.
Database work in a process the test starts needs the sandbox shared with it. Synchronize on
observable completion, not fixed sleeps.
