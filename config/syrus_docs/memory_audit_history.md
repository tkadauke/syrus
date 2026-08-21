# Memory Audit History

Every `ChatMemory` create/update/delete has always been recorded to the append-only
`ChatMemoryAuditEvent` table (`before_content`/`after_content`/`kind`/`confidence`,
actor, event type) via `ChatMemory#emit_created_audit_event` /
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

The **Memories** settings panel (`app/frontend/routes/Memories.tsx`) shows a
"Changed" badge on rows with audit history beyond creation; clicking it (or
the row's "History" action) opens a modal listing each audit event's
before/after content, kind, confidence, actor, and timestamp. A "View
deleted" / "View active" toggle switches the table between the normal
listing and the soft-deleted-memories view (which shows who deleted each
memory and when, and hides edit/publish/delete actions).

## Admin chat MCP tool

Admin and Supervisor chat agents can call `admin_read_memory_audit_history(memory_id)`
to read the same audit trail for any memory, including soft-deleted ones —
useful for diagnosing why a memory's content changed or was removed.
Registered `admin_only: true` in `McpToolRegistry`, so it is available to any
chat where the signed-in user is an admin, not only Supervisor chat.
