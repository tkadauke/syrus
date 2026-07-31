# Feature Flags

Syrus uses feature flags to gate experimental and operational behaviors. Flags are declared in `config/features.yml` and toggled in the admin UI under the Features tab (or via Rails console: `Feature.find_by(slug: 'slug').update(enabled: true)`).

All flags default to `false` (disabled).

## terminal

**Category:** Labs

Enables interactive terminal access inside workflow runs. When enabled, operators can open a PTY session attached to the agent's workspace from the Job detail page.

The terminal relay address is configured via `SYRUS_TERMINAL_HOST`. See the Terminal documentation for architecture details and how to enable.

## coding_mode

**Category:** Labs

Enables Coding Mode for Syrus Chat. When active, the chat workspace gets a writable full clone so the agent can implement code directly during a chat session instead of just planning. New chat-authored work starts on the repository default branch; accepted `submit_coding_changes` captures the current HEAD to an immutable `syrus/chat-<chat_id>-handoff-<pending_action_id>` branch, dispatches a `coding_handoff` workflow, then resets the chat checkout to the repository default branch tip and queues prep again for the next Coding Mode turn. Existing Job work can still use that Job's branch and hand off with `complete_implement_step`. Both handoff paths require operator confirmation before dispatching automation.

Coding Mode chats also expose `reset_workspace`. With no confirmation it is a status-only no-op that reports the checkout path, current branch/ref, default branch ref, dirty state, committed-ahead count, and prep status. If the checkout has uncommitted changes or commits ahead of the default branch, the tool refuses to reset unless called with `confirm_discard: true`. A confirmed reset discards local work, moves the checkout back to the repository default branch tip, clears dirty checkout state, and queues `ChatWorkspacePrepareJob`; a subsequent `submit_coding_changes` has no committed changes to capture until new work is done.

**Workspace reclamation.** A Coding-Mode checkout (writable full clone + installed dependencies) is commonly 1–2 GB, so Syrus reclaims that disk aggressively while never losing work:

- **After accepted `submit_coding_changes`** — once capture publishes the immutable handoff branch and the `coding_handoff` workflow starts, Syrus resets the chat checkout to a clean default-branch tip, clears dirty checkout state, and queues `ChatWorkspacePrepareJob` again.
- **After successful handoff workflow** — once graders pass and the PR is open, the checkout is already reproducible from remote state, so `ChatCodingWorkspaceReclaimJob` (on the `chat` queue) may free its disk.
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

## admin_supervisor_chat

**Category:** Operations

Enables one durable pinned Supervisor chat per admin user. The app admin API can open or provision the chat at `/api/v1/app/admin/supervisor_chat`; the endpoint returns `404` with `feature_disabled` while the flag is off and `403` for non-admins.

Supervisor chat identity is stored on `chat_sessions.system_kind = "supervisor"`, separate from the ordinary chat `mode` (`planning`, `coding`, `local`). A unique database index on `(user_id, system_kind)` enforces at most one Supervisor chat for each admin while allowing unlimited ordinary chats with `system_kind = NULL`.

While the flag is enabled, normal chat update paths cannot hide, delete, rename, or unpin the Supervisor chat. `SupervisorChat.ensure_for!(admin_user)` creates or repairs the affordance with title `Supervisor`, `pinned: true`, no repository attachment, and a populated `last_message_at`. The chat index payload exposes it as top-level `supervisor_chat`, not inside ordinary repository/general groups, so the app shell can render it as the single pinned admin control room above normal chats.

Major operational events are also recorded in the Supervisor chat while the flag is enabled. `SupervisorEvents.publish!(kind:, severity:, subject:, repository:, job:, epic:, proposal:, workflow:, run:, pr_number:, actor:, summary:, details:, dedupe_key:)` creates one `ChatScopedEvent` per admin Supervisor chat and enqueues `ChatScopedEventEvaluatorJob` for each new scoped event. The same publisher also resolves ordinary chats that originated the referenced work through confirmed proposal lineage: materialized proposals, Jobs, Epics, a Job's Epic, Workflows/Runs via their Job, and pull request numbers that map back to a Job. Ordinary chats only receive scoped events for matching originated work; unrelated Job/Epic events and generic chat attachments are ignored. The event row stores the target chat, source kind, structured payload, optional repository/Job/Epic/proposal ids, delivery state, dedupe key, and disposable evaluator result fields. `ChatScopedEventEvaluatorJob` evaluates one scoped event for its target chat in an isolated temporary provider session. It clones persisted chat context, preferring the full transcript, and falls back to the latest 10,000 messages plus a byte cap for very large content/tool outputs. The evaluator receives only read-only MCP tools and must return structured JSON (`no_op`, `respond`, or `act` with reason, urgency, confidence, and optional handoff prompt); Syrus persists that result and discards temporary provider transcript artifacts without mutating the live chat session. A `no_op` records the decision but creates no visible chat message and wakes no live turn. `respond` and `act` create an immediate real `ChatWakeup` whose user message contains the structured scoped event, evaluator decision, and handoff prompt; the live chat prompt explicitly tells the agent to read current Syrus state before acting on stale event data. The admin overview surfaces the evaluator pipeline for operators with recent scoped events, 24-hour `no_op`/`respond`/`act` counts, evaluator state counts, and recent failure reasons. Failed evaluator events can be retried, and already delivered actionable events are skipped on retry so visible wakeups are not duplicated. Publishing a scoped event still updates `last_message_at`, clears `last_read_at`, and broadcasts a chat update so the sidebar surfaces the event as unread even before any visible response exists. The index payload includes `supervisor_unread_count` and `supervisor_unread_severity` (`info`, `warning`, or `critical`) from unread Supervisor scoped events. The publisher no-ops completely while `admin_supervisor_chat` is disabled.

Supervisor agent turns receive the `chat:admin` role. Admin users keep the normal admin MCP tool set, but the Supervisor prompt directs the agent to treat `supervisor_event` system messages as operational context, summarize incidents, read current state before acting, and keep risky side effects behind proposals or pending-action confirmation. Chat-history fallback preserves Supervisor event messages and pending-action outcome notices so provider resume failures do not drop the audit trail that motivated an action.

Initial event sources are existing notifications (`NotificationService`) for job failures, implemented Jobs, merged PRs, PR feedback completion, upstream PR closure, Epic completion, and main-branch health changes, plus `submit_insight` when an Agent Insight suggestion becomes available. Callers should pass stable `dedupe_key` values for poll-driven events; the service suppresses duplicate scoped events for the same target chat to prevent repeated poll loops from flooding admins.

Major operational events are also recorded in the Supervisor chat while the flag is enabled. `SupervisorEvents.publish!(kind:, severity:, subject:, repository:, actor:, summary:, details:, dedupe_key:)` writes one durable `ChatMessage` system row per admin Supervisor chat with a plain `text` field for existing rendering/search plus structured `supervisor_event` metadata. It updates `last_message_at`, clears `last_read_at`, and broadcasts a chat update so the sidebar surfaces the event as unread. The publisher no-ops completely while `admin_supervisor_chat` is disabled.

Initial event sources are existing notifications (`NotificationService`) for job failures, implemented Jobs, merged PRs, PR feedback completion, upstream PR closure, Epic completion, and main-branch health changes, plus `submit_insight` when an Agent Insight suggestion becomes available. Callers should pass stable `dedupe_key` values for poll-driven events; the service suppresses duplicate keys observed in the recent Supervisor chat history to prevent repeated poll loops from flooding admins.

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

The admin performance endpoint returns the raw recent events plus grouped summaries for slow requests, slow phases, and SQL fingerprints. Each event is stamped with `app_revision` from `SyrusVersion.current` / `GIT_SHA`; the admin payload defaults to the current revision so stale pre-deploy timings do not dominate post-deploy analysis, with an all-revisions mode available for rolling-deploy overlap debugging. The diagnostics buffer is kept in a per-process memory ring capped at 200 events and flushed opportunistically to `Rails.cache` under `syrus:performance_logging:events:v1` at most once every 10 seconds, with a 6-hour cache expiry. In production that cache flush uses the configured cache store (`solid_cache_store`), but slow-event emission does not write Solid Cache for every event. Events are also written to structured application logs, so external log retention follows the deployment's log sink policy.

Implementation workflow agents working on `tkadauke/syrus` or a registered fork whose upstream is `tkadauke/syrus` receive the read-only `read_performance_diagnostics` MCP tool. Scheduled prompts that ask agents to improve Syrus performance can tell the agent to call this tool before changing code. It returns the same current-revision/all-revisions filtering semantics as the admin performance payload, plus bounded grouped slow-request, slow-phase, and SQL fingerprint summaries. Raw recent events are omitted unless `include_events` is true, still capped by `limit`, and sanitized to omit SQL samples, query strings, and obvious secret-bearing metadata.

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
