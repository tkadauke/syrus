---
title: API
description: REST API for external systems to create and manage Syrus Jobs.
---

# REST API

Syrus exposes an admin REST API for external operators and orchestrators.
Authenticate with an admin user's API token:

```bash
curl -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  https://syrus.example.com/api/v1/admin/overview
```

Non-admin tokens are rejected with `403 Forbidden`; missing or invalid
tokens return a JSON `401` error.

## Command Line Client

The repository includes a standalone Go CLI under `cli/`. It sends the
same bearer token header as the REST examples and exposes chat, inbox,
checkout, Job, Epic, repository, and schedule commands. See
[Syrus CLI](/docs/cli) for installation, login, command reference, and
terminal workflows.

## Terminal Sessions

When the `terminal` feature flag is enabled, user-scoped app API clients
can manage their own interactive terminal sessions. `GET
/api/v1/app/terminal_sessions` lists the authenticated user's running
sessions. `POST /api/v1/app/terminal_sessions` creates a session and accepts
optional `workflow_id`, `name`, and `working_directory` fields; when
`workflow_id` is present, Syrus defaults the working directory to that
Workflow workspace.

```bash
curl -X POST https://syrus.example.com/api/v1/app/terminal_sessions \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "workflow_id": 8454, "name": "Workflow 8454" }'
```

`GET /api/v1/app/terminal_sessions/:id` returns one session scoped to the
authenticated user, and `POST /api/v1/app/terminal_sessions/:id/kill` marks
that session killed so the relay terminates the PTY. Session payloads include
`id`, `name`, `working_directory`, `relay_address`, timestamps, `outcome`,
and `workflow_id`; they never include the relay auth token.

## Create a Direct Job

`POST /api/v1/admin/jobs` creates a direct Job and starts the normal
initial workflow when the Job is not blocked by dependencies or an Epic.
The Job belongs to the owner of the target repository, so the repository
owner's GitHub and agent credentials are used.

```bash
curl -X POST https://syrus.example.com/api/v1/admin/jobs \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "job": {
      "repository": "acme/widgets",
      "title": "Update the README",
      "prompt": "Add API setup instructions to the README.",
      "priority": "high",
      "agent_provider": "codex"
    }
  }'
```

Use either `repository_id` or `repository`/`repo` as `owner/name`.
Optional fields are `title`, `priority` (`high`, `medium`, `low`),
`agent_provider`, `epic_id`, and `owner_user_id`. When `title` is blank or
omitted, Syrus derives a short deterministic title from the prompt.

## Submit Job Feedback

All job and epic endpoints accept a numeric ID, the `JOB-<n>` / `EPIC-<n>`
prefix format, or a human-readable slug derived from the issue or epic title
(e.g. `/api/v1/app/jobs/repair-aqueduct`). Slugs are auto-generated at Job /
Epic creation and are unique per instance.

`POST /api/v1/app/jobs/:id/chat_feedback` lets the authenticated job owner
submit follow-up feedback directly, without confirming a chat pending action.
The Job must belong to the token user and be in `implemented` or `failed`
state. Syrus creates a `chat_feedback` Workflow on the existing branch.

```bash
curl -X POST https://syrus.example.com/api/v1/app/jobs/123/chat_feedback \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "body": "Please simplify the settings copy and keep the existing layout." }'
```

Blank feedback or a non-actionable Job returns `422` with a JSON error.

## File a Syrus Report Issue

`POST /api/v1/app/report_issue` lets the authenticated user file a GitHub
issue against the configured Syrus report repository. The default target is
`tkadauke/syrus`; operators can change `AppSetting.report_issue_repo_slug`.
The user must have a connected GitHub token.

```bash
curl -X POST https://syrus.example.com/api/v1/app/report_issue \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "title": "Chat composer bug", "body": "Context and reproduction steps." }'
```

The response is `{ "issue_url": "https://github.com/..." }`. Missing title
or GitHub credentials returns `422` with a JSON error.

## Create an Epic

`POST /api/v1/admin/epics` creates an Epic in a repository owned by the
repository's Syrus user.

```bash
curl -X POST https://syrus.example.com/api/v1/admin/epics \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "epic": {
      "repository": "acme/widgets",
      "title": "Documentation cleanup",
      "description": "Group the docs polish work.",
      "auto_approve_mode": "never"
    }
  }'
```

Optional fields are `github_issue_url`, `owner_user_id`, and
`auto_approve_mode`.

User-scoped clients can also create Epics through the app API with any
user API token:

```bash
curl -X POST https://syrus.example.com/api/v1/app/epics \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "epic": {
      "repository_id": 123,
      "title": "Documentation cleanup",
      "description": "Group the docs polish work."
    }
}'
```

## Rename a Chat

`POST /api/v1/app/chats/:id/rename` (also accepted as `PATCH`) renames one
of the authenticated user's chat sessions. `name` is required and must be
120 characters or fewer.

```bash
curl -X POST https://syrus.example.com/api/v1/app/chats/123/rename \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "name": "Release planning" }'
```

## Delete a Chat

`DELETE /api/v1/app/chats/:id` permanently deletes one of the authenticated
user's chat sessions: the conversation, its messages and bookmarks, queued
messages, attachments, proposals, pending actions, whiteboard, search-index
entries, and the chat workspace directory on disk. There is no undo — use
hide/unhide for reversible cleanup. The request is refused with `409
Conflict` (`error.code` `turn_in_flight`) while a turn is actively running.

```bash
curl -X DELETE https://syrus.example.com/api/v1/app/chats/123 \
  -H "Authorization: Bearer $SYRUS_API_TOKEN"
```

## Pin or Unpin a Chat

`PATCH /api/v1/app/chats/:id` accepts `{ "pinned": true }` or
`{ "chat": { "pinned": true } }` for one of the authenticated user's chat
sessions. Use `false` to unpin. Pinned chats sort ahead of unpinned chats in
the sidebar.

```bash
curl -X PATCH https://syrus.example.com/api/v1/app/chats/123 \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "chat": { "pinned": true } }'
```

Chat providers are pinned when a chat is created. The same endpoint also accepts
`{ "chat": { "chat_provider": "codex" } }` or `"claude"` to intentionally
switch an existing chat to another configured provider.

## Branch a Chat

`POST /api/v1/app/chats/:id/branch` creates a new chat session for the
authenticated user, attached to the same repository, with the current
transcript copied into it. The response includes the new chat `id` and
`app_path` for navigation.

```bash
curl -X POST https://syrus.example.com/api/v1/app/chats/123/branch \
  -H "Authorization: Bearer $SYRUS_API_TOKEN"
```

## Share a Chat

`POST /api/v1/app/chats/:id/share` creates a stable same-instance share
token for one of the authenticated user's chat sessions and returns
`share_url`. Repeating the request returns the same link.

```bash
curl -X POST https://syrus.example.com/api/v1/app/chats/123/share \
  -H "Authorization: Bearer $SYRUS_API_TOKEN"
```

`GET /api/v1/app/shared_chats/:token` is available to any authenticated user
on the same Syrus instance. It returns a read-only transcript payload with
chat metadata and messages only; unknown tokens return 404.

```bash
curl https://syrus.example.com/api/v1/app/shared_chats/8b0d6a08-6f8d-4a2e-b2d8-0f2a2a2d8f6f \
  -H "Authorization: Bearer $SYRUS_API_TOKEN"
```

## Hide or Restore a Chat

`PATCH /api/v1/app/chats/:id/hide` hides one of the authenticated user's
chat sessions from the default sidebar, search, and chat listing surfaces.
`PATCH /api/v1/app/chats/:id/unhide` restores it.

```bash
curl -X PATCH https://syrus.example.com/api/v1/app/chats/123/hide \
  -H "Authorization: Bearer $SYRUS_API_TOKEN"
```

`GET /api/v1/app/settings/hidden_chats` returns hidden chats ordered by
most recently hidden first. Results include `hidden_at`, repository context,
and an `app_unhide_path` for each row.

```bash
curl "https://syrus.example.com/api/v1/app/settings/hidden_chats?page=1" \
  -H "Authorization: Bearer $SYRUS_API_TOKEN"
```

## Search Chats

`GET /api/v1/app/search` searches the authenticated user's Jobs, Epics,
and chat messages with one relevance-ranked result list. Pass `q` with at
least two characters. Optional `types[]` values are `job`, `epic`, and
`chat`; omit `types[]` to search all three. `limit` defaults to 30 and is
capped at 100. Results include the result `type`, `id`, `title`, matched
`snippet`, normalized `rank`, app navigation `path`, state and repository
context for Jobs and Epics, and `created_at`. Job and Epic slugs such as
`JOB-123` and `EPIC-456` return the matching record when it belongs to the
authenticated user. Query terms use Google-style matching: `foo bar`
requires both words in any order, `"foo bar"` searches for the exact phrase,
and `foo "bar baz"` combines a required word with a required phrase. Chat
results are grouped by conversation: the best matching message is the
representative result, and grouped chat rows may include `grouped_matches`,
`total_match_count`, and `has_more_matches` for inline expansion.

```bash
curl "https://syrus.example.com/api/v1/app/search?q=deploy&types[]=job&types[]=chat" \
  -H "Authorization: Bearer $SYRUS_API_TOKEN"
```

`GET /api/v1/app/chats/search` searches the authenticated user's chats.
Hidden chats are excluded. Pass `q` for full-text search, or omit it for a
filter-only listing. The optional `repository_id`, `epic_id`, and `job_id`
filters limit results to chats with matching attachments. Results are
paginated with `page` and return chat-level cards with up to three matching
message snippets.

```bash
curl "https://syrus.example.com/api/v1/app/chats/search?q=deploy&epic_id=456" \
  -H "Authorization: Bearer $SYRUS_API_TOKEN"
```

`GET /api/v1/app/chats/search/messages` expands all matching messages for
one chat and query:

```bash
curl "https://syrus.example.com/api/v1/app/chats/search/messages?chat_session_id=123&q=deploy" \
  -H "Authorization: Bearer $SYRUS_API_TOKEN"
```

The app Epic detail API also supports dependency management for Epics owned
by the authenticated user:

```bash
curl -X POST https://syrus.example.com/api/v1/app/epics/456/dependencies \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "depends_on_epic_id": 123 }'
```

`POST /api/v1/app/epics/:id/dependencies` returns the refreshed Epic detail
payload, including `dependencies` and `dependents`. It rejects cycles.
`DELETE /api/v1/app/epics/:id/dependencies/:depends_on_epic_id` removes that
edge and is idempotent.

## Update Theme Preference

`PATCH /api/v1/app/theme` updates the authenticated user's app theme.
Valid values are `light` and `dark`.

```bash
curl -X PATCH https://syrus.example.com/api/v1/app/theme \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "theme": "dark" }'
```

## Manage Notifications

User-scoped clients can read and update the authenticated user's
notifications through the app API. `GET /api/v1/app/notifications` returns
newest-first paginated notifications and an `unread_count` envelope value.
Each notification includes `job_title` when it is associated with a Job. Pass
`unread=true` to list only unread notifications.

```bash
curl https://syrus.example.com/api/v1/app/notifications?unread=true \
  -H "Authorization: Bearer $SYRUS_API_TOKEN"
```

`PATCH /api/v1/app/notifications/:id/mark_read` marks one notification read
and returns the updated notification plus `unread_count`.
`POST /api/v1/app/notifications/mark_all_read` marks every unread
notification for the authenticated user read and returns the refreshed list.

`GET /api/v1/app/notification_preferences` returns the authenticated user's
merged notification category preferences. `PATCH
/api/v1/app/notification_preferences` accepts a partial
`notification_preferences` object and merges it into the saved preferences.

```bash
curl -X PATCH https://syrus.example.com/api/v1/app/notification_preferences \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "notification_preferences": { "epic_completed": true } }'
```

## Manage Memories

User-scoped clients can manage agent memories through the app API with any
user API token. `GET /api/v1/app/memories` returns paginated memories visible
to that user, including their own memories and repository-published memories
from repositories attached to them. It accepts `scope`, `kind`, `q`, and
`page` query parameters.

Write endpoints are owner-only unless the authenticated user is an admin:
`POST /api/v1/app/memories`, `PATCH /api/v1/app/memories/:id`,
`DELETE /api/v1/app/memories/:id`, `POST /api/v1/app/memories/:id/publish`,
and `DELETE /api/v1/app/memories/:id/publish`.
