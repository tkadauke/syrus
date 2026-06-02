---
name: syrus-debug
description: Debug Syrus deployments via the /api/v1/admin REST API. Use when the operator asks about stuck Jobs, failed Runs, queue starvation, MCP / claude-session issues, or any "what's going on with X" question that would otherwise need kubectl exec + Rails runner.
allowed-tools:
  - Bash(curl:*)
  - Bash(jq:*)
  - Bash(cat:*)
  - Bash(date:*)
  - Bash(echo:*)
---

# Syrus debug skill

Syrus exposes a small JSON admin API at `/api/v1/admin/*`. This
skill replaces the kubectl-cp + Rails-runner loop that used to
dominate Syrus debug sessions — one `curl` per question instead of
write-script → copy-in → exec → parse.

## Setup (operator does this once)

1. The operator sets `SYRUS_APP_HOST` to their Syrus app URL, for example
   `https://syrus.example.com`.
2. The operator generates a per-user API token at
   `$SYRUS_APP_HOST/credentials` (admin section). Token is shown ONCE;
   they save it to `~/.config/syrus/api-token` (chmod 600).
3. Skill assumes:
   ```bash
   SYRUS_BASE="${SYRUS_APP_HOST:?set SYRUS_APP_HOST to your Syrus URL}"
   SYRUS_TOKEN="$(cat ~/.config/syrus/api-token)"
   ```
4. Every call uses `Authorization: Bearer $SYRUS_TOKEN`.
5. Base URL may differ between environments, such as staging and
   production. Confirm the target `SYRUS_APP_HOST` with the operator
   before mutations.

## Investigation decision tree

Pattern: read the operator's question, pick the entry point, dig
from there. Don't run mutations without explicit operator
authorization.

### "Find the Syrus Job ID for this PR / issue"

You usually know the GitHub PR or issue number, not the Syrus Job ID.
Look it up:

```bash
curl -s -H "Authorization: Bearer $SYRUS_TOKEN" \
  "$SYRUS_BASE/api/v1/admin/jobs?pr_number=144&repo=owner/name" | jq .
```

Filters: `pr_number`, `issue_number`, `repo=owner/name`, `state`.
Returns a compact list (id, repo slug, issue/pr/branch, timestamps).
Pick the id from there and drill into the full state below.

### "Job N seems stuck / failed / weird"

```bash
curl -s -H "Authorization: Bearer $SYRUS_TOKEN" \
  "$SYRUS_BASE/api/v1/admin/jobs/N" | jq .
```

Returns the entire Job state in one shot — workflows, steps,
runs, claude_session metadata, run_diagnostic if present.

If a Run failed, drill into the transcript:

```bash
RUN_ID=...  # from the job dump
curl -s -H "Authorization: Bearer $SYRUS_TOKEN" \
  "$SYRUS_BASE/api/v1/admin/runs/$RUN_ID/transcript?per=300" \
  | jq '.summary, .events[]'
```

The transcript summary surfaces:
- `available_tools_at_init` — was the MCP tool registered?
- `mcp_tool_called` — did the agent ever invoke it?
- `tool_call_counts` — what shape was the run (heavy Bash?
  reading a lot? hitting WebFetch repeatedly?)
- `total_cost_usd`, `exit_reason` — terminal facts

If you need the full JSONL for grep / jq:
`GET /api/v1/admin/runs/:run_id/transcript/raw`

### "Things feel slow / nothing's happening / Turbo isn't updating"

Probably queue starvation. Check workers + recurring + active in order:

```bash
curl -s -H "Authorization: Bearer $SYRUS_TOKEN" \
  "$SYRUS_BASE/api/v1/admin/queue/workers" | jq .
# any worker with .stale = true → reaper / new RunJobs aren't being claimed

curl -s -H "Authorization: Bearer $SYRUS_TOKEN" \
  "$SYRUS_BASE/api/v1/admin/queue/recurring" | jq '.tasks[] | {key, last_run_at}'
# anything with last_run_at older than ~10 min → recurring scheduler is starved

curl -s -H "Authorization: Bearer $SYRUS_TOKEN" \
  "$SYRUS_BASE/api/v1/admin/queue/active" | jq '.jobs[] | {class_name, claimed_at}'
# many long-running RunJobs claimed for many minutes → workers saturated
```

### "Are sessions getting captured?" / "Is --resume actually working?"

```bash
curl -s -H "Authorization: Bearer $SYRUS_TOKEN" \
  "$SYRUS_BASE/api/v1/admin/overview" \
  | jq '.claude_session_capture_rate'
```

`rate < 0.8` means something's off with the session-capture path
(canonical-path encoding, MCP sidecar, JSONL not landing on
disk, etc.). Drill into a specific run's transcript to see the
session_id + the on-disk presence.

### "What's stuck right now?"

```bash
curl -s -H "Authorization: Bearer $SYRUS_TOKEN" \
  "$SYRUS_BASE/api/v1/admin/stuck" | jq .
```

`severity: "warn"` → the reaper will probably pick it up.
`severity: "alarm"` → the reaper *itself* isn't running. Cross-
reference with `/queue/recurring`.

### "Recent failures pattern"

```bash
curl -s -H "Authorization: Bearer $SYRUS_TOKEN" \
  "$SYRUS_BASE/api/v1/admin/queue/failed?since=$(date -u -v-2H +%FT%TZ)" \
  | jq '.failures[] | {class_name, exception_class, message}'
```

Same trigger_kind across many failures → likely a shared root
cause. ProcessPrunedError everywhere → a deploy SIGKILLed
in-flight Runs.

## Endpoint reference

### Reads (safe to call freely)

| Endpoint | Returns |
|---|---|
| `GET /api/v1/admin/overview` | Tile rollup: active/queued/failed counts, workers, recurring, GH rate limits, capture rate, stuck items |
| `GET /api/v1/admin/stuck` | Full stuck-items list (warn + alarm) |
| `GET /api/v1/admin/jobs` | Compact list. Filters: `pr_number`, `issue_number`, `repo=owner/name`, `state`. Use to map a GH PR/issue back to a Syrus Job ID |
| `GET /api/v1/admin/jobs/:id` | Job + workflows + steps + runs + diagnostics + claude_session metadata, all in one |
| `GET /api/v1/admin/epics` | Compact Epic list. Filters: `state`, `repo=owner/name`, `user`, `has_unfinished_children=true`. |
| `GET /api/v1/admin/epics/:id` | Full Epic + child jobs + dependency edges (depends_on + dependents) + pending dependency refs. |
| `GET /api/v1/admin/workflows/:id` | One workflow's steps + runs + diagnostics, no sibling workflows. Use when investigating a specific failure on a long-lived Job. |
| `GET /api/v1/admin/runs` | Cross-Job compact run list. Filters: `?state`, `?trigger_kind`, `?job_id`, `?since=ISO8601`. Pagination: `?page` + `?per` (max 100). Use for "what failed across the system in the last hour" without walking each Job. |
| `GET /api/v1/admin/runs/:run_id/transcript[?page=N&per=K]` | Parsed transcript: summary + paginated events |
| `GET /api/v1/admin/runs/:run_id/transcript/raw` | Raw JSONL bytes |
| `GET /api/v1/admin/queue/active` | SolidQueue jobs currently claimed |
| `GET /api/v1/admin/queue/pending` | Queued, not yet claimed (with total) |
| `GET /api/v1/admin/queue/failed[?since=ISO8601]` | Recent failed_executions |
| `GET /api/v1/admin/queue/recurring` | Recurring tasks + last_run_at + last_finished_at |
| `GET /api/v1/admin/queue/workers` | Workers (with stale flag) + all_processes |
| `GET /api/v1/admin/processes` | Subprocess inventory (agent/grader/git/prepare). Filters: `state=running|finished|all`, `kind`, `hostname`, `run_id`, `workflow_id`, `since=ISO8601`. Use for "what's running right now across the whole worker pool" or "show me everything a particular Run spawned". |
| `GET /api/v1/admin/processes/:id` | One subprocess record + host metrics (CPU%, RSS bytes) when still running. Read from /proc on Linux. |

### "What's a wedged worker actually doing?"

When the queue feels stuck but the workers look "alive", check the
subprocess inventory before assuming SQ is to blame:

```bash
curl -s -H "Authorization: Bearer $SYRUS_TOKEN" \
  "$SYRUS_BASE/api/v1/admin/processes?state=running" \
  | jq '.processes[] | {kind, command: .command[0:80], stale, duration_s, hostname}'
```

A subprocess marked `stale: true` whose `duration_s` exceeds the
typical wall-clock window for its kind is the agent or grader that's
holding up the chain. The `Run` link points at the transcript.

### Mutations (require explicit operator authorization)

Always confirm with the operator before calling. Phrase as
"I'd like to call POST /workflows/N/retry_step — that reopens the
workflow + creates a fresh Run. OK?"

| Endpoint | Effect |
|---|---|
| `POST /api/v1/admin/queue/reap_stale_runs` | Runs ReapStaleRunsJob inline. Safe — same code path the recurring scheduler runs every minute. |
| `POST /api/v1/admin/workflows/:id/retry_step` | Reopens workflow + failed step, creates a fresh Run. Inline-chain dispatch picks it up. |
| `POST /api/v1/admin/workflows/:id/cleanup_workspace` | Tears down the workspace ahead of WorkflowWorkspacePruneJob's daily sweep. **Destroys** committed-but-unpushed work in the workspace; check `workflow.cleaned_up_at` first to confirm it's not already gone. |
| `POST /api/v1/admin/processes/:id/kill` | Stamps `kill_requested_at` on the SpawnedProcess. The owning worker's ProcessRunner polls the flag once a second and terminates the local pid (TERM then KILL after 5s grace). Cross-pod safe — the web pod can't signal worker pids directly, this is the DB-based handshake. Returns 409 if already finalized. |

## Error envelope

Every error response has this shape:

```json
{ "error": { "code": "not_found", "message": "Couldn't find Job with 'id'=99999" } }
```

Codes worth knowing:
- `unauthorized` — bad/missing token
- `forbidden` — token's user isn't admin
- `not_found` — record doesn't exist
- `bad_request` — missing param
- `queue_unreachable` — SolidQueue tables not in this connection (dev/test); expected in non-prod environments
- `workflow_not_failed`, `workspace_cleaned_up`, `no_failed_step` — retry_step refusals

## Notes

- The HTML admin UI at `/admin` (overview + queue + transcript +
  stuck pages) is the human-friendly surface for the same data.
  Use the API for programmatic / scripted investigation.
- Token rotation invalidates the prior token immediately. If
  your curl starts returning 401, ask the operator if they
  rotated.
- `bearer` header is the only auth method. No cookie-based
  session reuse from the browser.
