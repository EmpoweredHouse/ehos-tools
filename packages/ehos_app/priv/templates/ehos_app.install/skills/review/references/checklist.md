# Review checklist

One section per lens in `../SKILL.md`. Mark each item PASS / FAIL / N/A; a FAIL is a finding. Each
item names the file or check that is the source of truth; the reasoning lives in the doc named in
the heading, not here.

## Boundaries & security — `ARCHITECTURE.md`, `docs/auth.md`

- [ ] Every PostgreSQL write is the backend's; nothing in `apps/ai` (MCP included) writes the DB.
- [ ] `apps/web` talks only to the backend (REST + WebSocket), never to AI or BigQuery.
- [ ] BigQuery only through `apps/bigquery`; its SQL validation still blocks INSERT/UPDATE/DELETE/DROP.
- [ ] Service-to-service calls carry `X-API-Key`; a missing key crashes at boot, with no fail-open default.
- [ ] The wiki agent stays on its run-scoped bearer token under `/api/agent`: no `X-API-Key` for it,
      no endpoint beyond what one run needs (`docs/wiki.md`).
- [ ] MCP tools stay read-only: annotated `readOnlyHint=True`, no write registered (`apps/ai/src/mcp/server.py`).
- [ ] No secrets in code; input validated at the edge (Ecto changesets, Zod, Pydantic).

## Tenancy — `docs/tenancy.md`

- [ ] Every read and write on a tenant table passes an explicit prefix
      (`prefix: organization.schema_prefix`, or the scoped fixture helpers) — no `search_path` reliance.
- [ ] Identity lives in public, business records in the organization's schema; a new migration is in
      `apps/backend/apps/database/priv/repo/public_migrations` or `tenant_migrations` accordingly.
- [ ] A job goes on the one public `Oban` instance with `organization_id` in its args; its worker
      resolves the prefix from the registry, and every `unique` key and direct `Oban.Job` query
      includes `organization_id`.
- [ ] A tenant route, socket, job or service call refuses an organization whose setup is not
      `ready`; only organization management (rename, BigQuery configuration, members, invitations,
      setup retry) skips that check.
- [ ] Tests have one sandbox owner (the domain `DataCase` / `*.TenantFixtures`); a spawned DB caller
      gets `async: false` or an explicit allowance, never a second checkout.
- [ ] No lookup by id alone that could return another organization's row.

## Frozen contracts and mirrors — `docs/copilot.md`

- [ ] SSE events between `apps/ai/src/agents/shared/streaming.py` and
      `Api.Ai.Handlers.StreamingHandler`: names and payloads unchanged, additions only.
- [ ] An internal view the AI reads changed shape → its spec in
      `apps/backend/apps/api_web/test/api_web/controllers/ai_contract_test.exs` **and** the model in
      `apps/ai/src/services/backend_models.py` change in the same PR (triage in that test's moduledoc).
- [ ] Claims taxonomy: `Claims.Taxonomy` (the authority) and `apps/ai/src/agents/claims/taxonomy.py`
      agree — `tests/agents/claims/test_taxonomy_contract.py`.
- [ ] View context: `apps/web/src/types/view-context.ts` and `apps/ai/src/models/chat.py` agree —
      `tests/test_view_context_contract.py`.
- [ ] WebSocket topics, OAuth endpoints and MCP tool names are not renamed or removed.
- [ ] JSON is camelCase; web types match the backend view (names, nullability, enums).

## Migrations & rollout — `docs/deployment.md`

- [ ] Reversible: `change` that Ecto can invert, or both `up` and `down`.
- [ ] New columns are nullable or defaulted; constraints land after the data is clean; indexes on big
      tables are `concurrently`.
- [ ] Migrations run **before** the new revision rolls out, so the old revision must survive the new
      schema: a drop (`remove`, `drop`, `drop_if_exists`) ships in two deploys — code that stops
      reading it first, the drop in a later commit. A PR carrying both is the bug; `skip_migrations`
      cannot hold the drop back.
- [ ] After a rename or removal, `git grep <old_name>` hits only migration and schema files; any other
      hit (serializer, type, prompt, fixture, component, doc) is stale.

## Invalidation net — `apps/web/AGENTS.md`

- [ ] Query keys come from `apps/web/src/lib/query-keys.ts`; mutations declare
      `meta.invalidates: declareInvalidates(...)` — no key literals, no `invalidateQueries` call
      sites; every `rawKey`, `invalidates: []` or guard carries a comment saying why.
- [ ] A backend payload that newly embeds another domain's data (owner name, metric snapshot,
      assignments) has its edge in `FANOUT` (`apps/web/src/lib/invalidation-net.ts`) — an embedding
      is an invalidation edge.
- [ ] Each net declaration is asserted in its own hook's test.
- [ ] React Query and `apiFetch` stay in `hooks/` and `services/`; components and pages use hooks.

## Approval-gated tools — `docs/copilot.md`

- [ ] A copilot tool that writes is listed in `APPROVAL_REQUIRED_TOOLS`
      (`apps/ai/src/agents/shared/approvals.py`); `ApprovalRequiredToolset` enforces it, so the tool
      body carries no approval code of its own.
- [ ] A new write (`apply_*` and the like) has its entry in `WRITE_TOOLS`
      (`apps/web/src/lib/parse-agent-write.ts`) so the card links it and the net refreshes the right
      domain; `describe-tool-call.test.ts` names every gated tool.
- [ ] A mention picks a target and never grants permission; auto-accept stays per conversation.

## Wiki writers — `docs/wiki.md`

- [ ] A run writes the tree; a person opens a `watch_topic` (`Wiki.Topics`) and corrects one named
      page (`Wiki.Corrections`); `Wiki.PageType` says which page types belong to which writer.
- [ ] A new caller of `Wiki.Edit.publish/2` does the page-type and roster check `Wiki.Corrections`
      does — `publish/2` takes any `.md` path and `Wiki.RunScope` returns no findings for an edit.
- [ ] Nothing lets a run open, delete or re-aim a `watch_topic`.
- [ ] The live pointer moves only through `Wiki.Pointer.swap/2`; no `live` value in `wiki_runs.status`.
- [ ] Linter, `apps/wiki-agent/skills/**` or `PHASE_SKILLS` changed → `Wiki.EscriptParityTest`,
      `Wiki.SkillAgreementTest` and `apps/wiki-agent/tests/test_skills.py` pass against a rebuilt
      escript and `wiki-agent:dev` image.
- [ ] `apps/wiki-agent`: provider secrets stay with the root SDK host (`bin/security.py`,
      `bin/cli_bridge.py`); input files stay protected; claim lookup tools stay read-only.

## App conventions — `apps/<app>/AGENTS.md`

- [ ] Backend: context functions return `{:ok, _}` / `{:error, _}` with `@spec`; controllers delegate
      to contexts (no `Repo` in controllers); `claims`/`wiki` never depend on `:api`, `claims` never on `wiki`.
- [ ] Backend test refactors preserve meaning and follow
      [`TESTING.md`](../../../../apps/backend/TESTING.md). Style alone is P2.
- [ ] Web: named exports, no barrel files, `@/` imports, no `any`; Zustand for client state, React
      Query for server state, Context for scope; `apiFetch()` for HTTP; UI follows the `eh-design` skill.
- [ ] AI: test mocks build real pydantic-ai event dataclasses, not `Mock()`; deps via
      `async with create_*_deps(...)`; type hints throughout.
- [ ] Moduledocs say what the module is and its contract; rationale lives in the doc, not restated.

## Docs — root `AGENTS.md`

- [ ] Behaviour, a contract or a decision changed → the owning doc (`docs/*.md`,
      `apps/<app>/AGENTS.md` or `TESTING.md`) is updated in this PR; a shipped plan's lasting content
      moved there.
- [ ] No `ADR NNN` or `docs/adr/` citations; comments link a doc file, not a section number
      (`make check-docs`).
- [ ] Tests came with the change, and `make check-<app>` + `make test-<app>` are green for every touched app.
- [ ] Conventional commits; no `Co-Authored-By` or other AI attribution.
