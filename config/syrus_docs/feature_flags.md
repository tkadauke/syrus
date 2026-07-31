# Feature Flags

Syrus uses feature flags to gate experimental and operational behaviors. Flags are declared in `config/features.yml` and toggled in the admin UI under the Features tab (or via Rails console: `Feature.find_by(slug: 'slug').update(enabled: true)`).

All flags default to `false` (disabled).

## terminal

**Category:** Labs

Enables interactive terminal access inside workflow runs. When enabled, operators can open a PTY session attached to the agent's workspace from the Job detail page.

The terminal relay address is configured via `SYRUS_TERMINAL_HOST`. See the Terminal documentation for architecture details and how to enable.

## coding_mode

**Category:** Labs

Enables Coding Mode for Syrus Chat. When active, the chat workspace gets a writable full clone so the agent can implement code directly during a chat session instead of just planning. New chat-authored work starts on the repository default branch; accepted `submit_coding_changes` captures the current HEAD to an immutable `syrus/chat-<chat_id>-handoff-<pending_action_id>` branch. Existing Job work can still use that Job's branch and hand off with `complete_implement_step`. Both handoff paths require operator confirmation before dispatching a `coding_handoff` workflow.

**Workspace reclamation.** A Coding-Mode checkout (writable full clone + installed dependencies) is commonly 1–2 GB, so Syrus reclaims that disk aggressively while never losing work:

- **On successful handoff** — once the branch is pushed and the PR is open, the checkout is fully reproducible from the remote, so `ChatCodingWorkspaceReclaimJob` (on the `chat` queue) frees it.
- **When idle** — `WorkflowWorkspacePruneJob` reclaims checkouts inactive longer than `ChatWorkspace::RECLAIM_IDLE_CODING_AFTER` (48 h).
- **Under disk pressure** — when retained checkouts exceed `AppSetting.chat_coding_workspace_budget_mb` (`0` = unlimited), the least-recently-active are LRU-evicted.

Reclamation is safe and transparent: before deleting, standalone default-branch chat work is backed up to a `syrus-wip/chat-<id>` tag ref, so Syrus never pushes local chat commits directly to `refs/heads/<default>`. If the checkout is on a non-default Job/user branch, Syrus pushes that branch and snapshots any uncommitted work to the same WIP tag. The session keeps `coding_checkout_branch` as the restore/source ref, so the next chat turn re-clones the ref and consumes the WIP snapshot before the agent runs — the agent cannot tell the workspace was ever removed. If a backup push fails, the on-disk checkout is preserved rather than deleted. See `AppSetting.chat_coding_workspace_budget_mb`.

**Multi-pod (Kubernetes) setup.** The three coding sidebar endpoints (`coding_files`, `coding_file`, `coding_diff`) proxy to a lightweight HTTP relay running on the `chat` queue worker. The relay address is recorded per-session in `chat_sessions.coding_relay_address`. For web pods to reach the worker relay, set `SYRUS_TERMINAL_HOST` to the worker pod IP via the Downward API field `status.podIP` on worker pods — the same setting used by the terminal feature. In single-host and Docker Compose deployments the relay binds to `127.0.0.1` and both web and worker share the same host, so no additional configuration is needed.

## video_walkthroughs

**Category:** Labs

**Requires:** A Gemini API key configured on the user's account (`User#gemini_api_key`).

Enables walkthrough video intake in Syrus Chat. Operators can record or drag in a narrated screen recording (webm/mp4/mov, ≤15 min, ≤500 MB). Gemini analyzes the video; the chat agent uses the analysis to propose an Epic. See the Video Walkthroughs documentation for the full flow.

## local_mode

**Category:** Labs

Enables the Local chat mode and the `syrus local` daemon command. The agent connects to a daemon running on the user's local machine via a reverse WebSocket tunnel to read/write files and run commands locally, without requiring a server-side clone.

## chat_polish

**Category:** UI Experiments

Adds subtle motion-safe chat animations: new messages fade in, the jump-to-bottom scroll is smooth. Respects the user's `prefers-reduced-motion` setting.

## performance_logging

**Category:** Operations

Records structured slow-request, SQL query, and phase-timing events to logs and a short-lived admin diagnostics buffer. Useful for profiling production performance. No user-facing impact.

When enabled, Syrus emits:

- `syrus.performance.slow_request` for controller requests slower than `SYRUS_PERFORMANCE_SLOW_REQUEST_MS` (default 1000 ms), including request id, method, path, controller/action, status, current user id/admin flag when available, request SQL counts/duration, and the top SQL fingerprints observed during the request.
- `syrus.performance.slow_sql` for SQL statements slower than `SYRUS_PERFORMANCE_SLOW_SQL_MS` (default 250 ms), including request context, SQL name, a truncated SQL sample, duration, and a normalized fingerprint.
- `syrus.performance.slow_phase` for instrumented application phases slower than `SYRUS_PERFORMANCE_SLOW_PHASE_MS` (default 250 ms), including request context and sanitized metadata.

Request phase instrumentation covers complex app/admin payloads that are likely to become performance bottlenecks over time, including dashboard rows/chrome, smart folders, job detail, repository list/detail, chat open/index/message payloads, bootstrap/setup status, spending, and admin overview/queue payloads. The phase wrappers are gated by the feature check, so the disabled-path cost is intended to stay very low.

The admin performance endpoint returns the raw recent events plus grouped summaries for slow requests, slow phases, and SQL fingerprints. Each event is stamped with `app_revision` from `SyrusVersion.current` / `GIT_SHA`; the admin payload defaults to the current revision so stale pre-deploy timings do not dominate post-deploy analysis, with an all-revisions mode available for rolling-deploy overlap debugging. The diagnostics buffer is stored in `Rails.cache` under `syrus:performance_logging:events:v1`, capped at 200 events, and expires after 6 hours. In production this uses the configured cache store (`solid_cache_store`), not a dedicated durable audit table. Events are also written to structured application logs, so external log retention follows the deployment's log sink policy.

## unified_work_engine_reconciler

**Category:** Operations

Makes the unified work-engine reconciler authoritative for work-state recovery.

Default is **off**, which preserves the legacy engine: `ReapStaleRunsJob`,
`AutoRetryScheduler`, `ReconcileJobStatesJob`, and the existing admin stuck
detection/reaper action continue to run through their current mutation paths.

When enabled, legacy disconnected fixers do not independently mutate work
state. The stale-run reaper, auto-retry scheduler, Job-state reconciler, and
manual admin reap action defer to `WorkEngine::Reconciler` through
`WorkEngine::ReconcileJob` instead, so unified reconciliation is the single
authority for classifying and repairing split-brain work state.

Diagnostic reconciler calls remain read-only by default. The feature-gated
recurring repair path executes only repair plans marked `auto_executable`, and
audits each action to system logs plus `JobLog` when a Run is available. See
`work_engine_reconciler.md` for the issue families, result shape, and execution
contract. Admin stuck visibility and the structured `explain_stuck_job` chat
tool use the reconciler's read-only classifications and repair plans so
operators see the same reason, wait/repair/operator status, and evidence that
the repair loop uses.
