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

From a local checkout whose `origin` remote matches the Job's repository,
use `syrus checkout JOB-456` to fetch and check out the Job branch. If the
Job has not created a branch yet, the CLI exits with a clear state-specific
message instead of changing the checkout.

## Print a Job Test Plan

`syrus test-plan JOB-456` fetches `GET /api/v1/admin/jobs/456`
and prints the newest completed workflow's `test_plan` artifact as a
numbered checklist, followed by notes when present.

Run `syrus login` first with an admin user's API token, then ask for the
plan:

```bash
syrus test-plan JOB-456
```

If no completed workflow has published a test plan yet, the command says
the plan is not available and that the Job may still be implementing.

After reviewing and testing a Job locally, approve it from the terminal:

```bash
syrus approve JOB-456
```

On success the command prints `Approved JOB-456. Landing will begin shortly.`
If Syrus rejects the approval, for example because the Job is not ready or
auto-merge is disabled, the CLI prints the API error and exits non-zero.

Use `syrus status` to list active Jobs across repositories:

```bash
syrus status
syrus status --repo acme/widgets
syrus status --closed
```

The command calls `GET /api/v1/admin/jobs?state=open` by default and prints
a compact 80-column table with Job ID, repository, title, state, and PR
number. Terminals with color support highlight running, implemented,
approved, failed, and queued states.

Read-only inspect commands use the app-scoped API and work with the
configured user's own Jobs, Epics, and repositories. When run inside a
GitHub checkout, list/search commands scope to that repository's
`owner/name`; outside a checkout they fall back to all repositories the
user can see.

```bash
syrus whoami
syrus repo list

syrus job list --state open --limit 20
syrus job search "dark mode"
syrus job show 456
syrus job log 456
syrus job watch 456
syrus job diff 456
syrus job create
syrus job approve 456
syrus job cancel 456
syrus job retry 456
syrus job rebase 456
syrus job checkout 456
syrus job test-plan 456
syrus job open 456

syrus epic list
syrus epic search "launch"
syrus epic show 12
```

`job log` pages completed transcripts through `$PAGER` and streams
running transcripts until the Job finishes or the command is interrupted.
`job diff` fetches the pull request diff through Syrus' GitHub credential;
if no GitHub token is available, it prints the pull request URL instead.

Action commands use the app API with the same bearer token. `job create`
prompts for a title and multi-line description, defaults to the current
GitHub checkout's repository, and accepts `--repo owner/name` and `--yes`.
`job checkout` verifies the current checkout matches the Job repository,
fetches the Syrus branch from `origin`, and checks it out locally.

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
