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

`POST /api/v1/app/chats/:id/rename` renames one of the authenticated
user's chat sessions. `name` is required and must be 60 characters or
fewer.

```bash
curl -X POST https://syrus.example.com/api/v1/app/chats/123/rename \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "name": "Release planning" }'
```

## Update Theme Preference

`PATCH /api/v1/app/theme` updates the authenticated user's app theme.
Valid values are `light` and `dark`.

```bash
curl -X PATCH https://syrus.example.com/api/v1/app/theme \
  -H "Authorization: Bearer $SYRUS_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "theme": "dark" }'
```
