# Admin API improvements

A running list of cases where the agent (or operator) tried to investigate
something via `/api/v1/admin/*` and hit a wall — either the data wasn't
exposed, the filter didn't exist, or the endpoint outright errored.
Each entry: the investigation that triggered it, what blocked, what to
add. Build incrementally as the painful spots show up; not a big
single-PR effort.

## Open


## Resolved

### Sensitive-data boundary in admin API responses

What the admin API redacts vs returns verbatim:

**NEVER returned in any response (or response body):**
- `User#github_token`, `User#claude_oauth_token`, `User#api_token`
  (deterministic-encrypted in the column; not exposed via the
  serializers).
- `User#password_digest`.
- `RAILS_MASTER_KEY`, `SECRET_KEY_BASE`, DB credentials — runtime
  env, not in any model.
- The `https://x-access-token:<token>@github.com/...` push URLs
  that would otherwise appear in git output: `GitRunner` redacts
  the token to `[REDACTED]` (regex `AUTH_URL_PATTERN`) before the
  text reaches its `log_sink`, so the token never makes it into a
  JobLog row in the first place. Raw log dumps from
  `/api/v1/admin/jobs/:id` are safe to share.

**Returned in full to admin tokens (intentional):**
- `Run#agent_diff` (via `/transcript/raw`-equivalent paths) and
  `Run#agent_summary` / `agent_pr_title` / `agent_pr_body` — the
  operator owns the output of their own agents.
- Provider transcript JSONL — the operator's own agent conversation,
  including the prompts they sent and the agent's output. Required for
  transcript inspection via the UI/API to serve any debugging purpose at
  all.
- `RunDiagnostic#error_message`, `JobLog#chunk` — plaintext stack
  traces, agent stdout. Token-redaction (above) is the only filter.
- `User#email_address`, `gh_rate_limit_*` — surfaced to admins for
  cross-user investigation.

**Auth posture:**
- API tokens are `User#api_token`, deterministic-encrypted, prefixed
  `syrus_`. Auth via `Authorization: Bearer <token>`.
- Every `/api/v1/admin/*` endpoint requires the bearer token AND
  `User#admin?` — non-admin tokens get 403 with a structured error.

If a future audit asks "could a user access another user's data via
the API?" — the answer should be "only if they're an admin." The
admin tier is single-tenant by design (the operator runs Syrus for
themselves, the team if any is small and trusted). If multi-tenant
admin segmentation ever becomes a goal, that's a much bigger
project than what fits in this file.

### `GET /api/v1/admin/runs` (cross-Job Run lookup)

Compact list mirroring the JobsController#index shape but for Runs.
Filters: `?state`, `?trigger_kind`, `?job_id`, `?since` (ISO8601);
pagination via `?page` + `?per` (default 50, max 100). Each row
carries job_id + step_kind + workflow_state + agent_outcome +
error_class so the operator can scan "what failed" without follow-up
calls. Bad `?since` values degrade to wide-window rather than 400'ing.

### `GET /api/v1/admin/workflows/:id` (single-workflow detail)

`GET /api/v1/admin/jobs/:id` returns every Workflow on a Job, which
is heavy for long-lived Jobs (today's Job 80 has 17). The new
endpoint returns one Workflow's nested state (steps + runs +
diagnostics + claude_session metadata) plus a thin Job envelope so
the caller can drill back up. Reuses `Admin::JobStateSerializer`
(extracted from JobsController) — same per-record-resilience.

### List filters on `/api/v1/admin/jobs`

Three new filters: `?failed_in_last_24h=true` (Jobs whose LATEST
workflow ended `failed` within 24h — careful not to re-surface fixed
work), `?has_active_workflow=true` (Jobs with queued/running
workflows), `?user=substring` (User#email_address LIKE matching).
The "latest workflow" filter uses a `ROW_NUMBER() OVER (PARTITION BY
job_id ORDER BY created_at DESC)` window function so a Job that
failed but was successfully retried doesn't show up.

### Serializer resilience for `/api/v1/admin/jobs/:id`

Triggered by `Job 80` returning 500 because `serialize_run` called
`.bytesize` on a transcript that was pruned post-success
(`804cdf5`). Two-part fix:

1. Nil-safe the transcript fields directly + flag pruned bodies via
   `transcript_pruned: true/false` instead of pretending size 0
   (commit `c5e9027`).
2. Wrap each per-record serializer (`serialize`, `serialize_workflow`,
   `serialize_step`, `serialize_run`) in a `rescue => e` that swaps
   in `{ id: ..., error_serializing: "Class: message" }` and logs
   the error. One bad row no longer 500s the whole nested dump.
