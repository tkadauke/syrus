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

The repository includes a standalone Go CLI scaffold under `cli/`. It is
separate from the Rails app and builds to a single `syrus` binary:

```bash
cd cli
make build
```

Run `syrus login` once to write `~/.syrus/credentials`:

```text
url=https://syrus.example.com
token=your-api-token
```

The CLI sends the same bearer token header as the REST examples:
`Authorization: Bearer <token>`. If credentials are missing or incomplete,
it prints `Run 'syrus login' to set up your Syrus instance URL and API token.`

Run `syrus` with no subcommand to pick from recent chat sessions, create a
new session, and enter the interactive chat REPL:

```bash
syrus
```

The picker calls `GET /api/v1/app/chats`, puts sessions attached to the
current GitHub repository first when run inside a checkout, and uses
`POST /api/v1/app/chats` for a new session. The REPL sends each line as a
streaming turn until Ctrl+D exits. Ctrl+C stops the active turn and returns
to the prompt.

When a chat turn proposes a Job or Epic, the CLI pauses the stream and shows
an inline proposal card. Press `c` to confirm and file it through the app
proposal endpoint, or `s` to skip it. Multiple proposals in one turn are
handled one at a time before the REPL prompt returns.

The CLI can also send a single streaming chat turn:

```bash
syrus chat 123 "Inspect the queued proposals"
```

Chat streaming posts to `/api/v1/app/chats/:id/message` with
`Accept: text/event-stream`, prints assistant chunks as they arrive, and
renders Markdown with terminal wrapping. Pressing Ctrl+C asks Syrus to stop
the in-flight turn instead of crashing the CLI process. Unlike the admin
REST endpoints above, chat streaming accepts the owning user's API token
for chats that user can access.

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
Optional fields are `priority` (`high`, `medium`, `low`), `agent_provider`,
`epic_id`, and `owner_user_id`.

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
