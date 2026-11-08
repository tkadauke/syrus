# Memory Audit History

> Agent memory ships as the `agent_memory` plugin (enabled by default). It is
> the registered `memory_store` provider, so disabling it removes the memory
> tools, the Memories settings page, and the memory section of agent prompts —
> see `plugins.md`. Existing rows are untouched by disabling; removing them is
> `bin/rails 'plugin:purge[agent_memory]'`.

Every `AgentMemory::Entry` create/update/delete has always been recorded to the append-only
`AgentMemory::AuditEvent` table (`before_content`/`after_content`/`kind`/`confidence`,
actor, event type) via `AgentMemory::Entry#emit_created_audit_event` /
`#emit_updated_audit_event` / `#emit_deleted_audit_event`. This feature surfaces
that trail and soft-deleted memories to operators and admins.

## Backend

- `GET /api/v1/app/memories/:id/audit_events` — returns a memory's full audit
  trail, oldest first, including memories that have since been soft-deleted.
  Admin-or-owner scoped, same permission model as the rest of
  `Api::V1::App::MemoriesController` (`find_memory_for_owner_or_admin`).
- `GET /api/v1/app/memories?deleted=true` — lists soft-deleted memories instead
  of active ones. Same admin-or-own visibility scoping as the normal listing;
  the response's top-level `deleted` boolean reflects which view was served.
- The memory index payload includes a `changed` boolean per row — true when a
  memory has any audit event beyond its initial `created` one (an `updated` or
  `deleted` event).

## Frontend

The **Memories** settings panel (`plugins/agent_memory/app/frontend/routes/Memories.tsx`) shows a
"Changed" badge on rows with audit history beyond creation; clicking it (or
the row's "History" action) opens a modal listing each audit event's
before/after content, kind, confidence, actor, and timestamp. A "View
deleted" / "View active" toggle switches the table between the normal
listing and the soft-deleted-memories view (which shows who deleted each
memory and when, and hides edit/publish/delete actions).

## Admin chat MCP tool

Admin chat agents can call `admin_read_memory_audit_history(memory_id)`
to read the same audit trail for any memory, including soft-deleted ones —
useful for diagnosing why a memory's content changed or was removed.
Registered `admin_only: true` in `McpToolRegistry`, so it is available to any
chat where the signed-in user is an admin.

## Chat memory preflight

`AgentMemory::Store.chat_instructions` (the plugin's `memory_store` provider)
requires a procedural preflight before consequential chat actions: drafting or
submitting a Job/Epic proposal, scheduling unattended work, changing priority
or dependencies, requesting an administrative repair, or any other
consequential mutation. The agent must list visible `user_pref` memories
(`limit: 100`), search memories with terms from the action and its subject,
read any truncated match, and apply what it finds before choosing tool
arguments. If the memory tools fail, the agent reports that the preflight could
not be completed and skips the mutation.

It is procedural rather than classifier-based on purpose: the agent's own
judgment that prior context "seems relevant" is exactly what failed (an
operator-owned priority preference existed but was never queried), and a
classifier, new memory kinds, applicability tags, or a two-phase tool protocol
would add machinery with the same blind spot. Ordinary read-only answers stay
lightweight and need no search. The guidance lives in the plugin: with Agent
Memory disabled, chat prompts carry no memory section or memory-tool
requirement, and coworker chats keep their own workspace-memory instructions.
