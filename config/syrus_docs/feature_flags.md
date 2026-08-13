# Feature Flags

Syrus uses feature flags to gate experimental and operational behaviors. Flags are declared in `config/features.yml`, parsed through `FeatureRegistry`, and toggled in the admin UI under the Features tab (or via Rails console: `Feature.find_by(slug: 'slug').update(enabled: true)`).

All current flags are typed booleans and default to `false` (disabled). Keep the YAML declaration, `FeatureRegistry` metadata, and this reference aligned when adding or changing a flag.

## terminal

**Category:** Labs

Enables interactive terminal access inside workflow runs. When enabled, operators can open a PTY session attached to the agent's workspace from the Job detail page.

The terminal relay address is configured via `SYRUS_TERMINAL_HOST`. See the Terminal documentation for architecture details and how to enable.

## coding_mode

**Category:** Labs

Enables Coding Mode for Syrus Chat. When active, the chat workspace gets a writable full clone so the agent can implement code directly during a chat session instead of just planning. New chat-authored work starts on the repository default branch; accepted `submit_coding_changes` captures the current HEAD to an immutable `syrus/chat-<chat_id>-handoff-<pending_action_id>` branch, dispatches a `coding_handoff` workflow, then resets the chat checkout to the repository default branch tip and queues prep again for the next Coding Mode turn. Existing Job work can still use that Job's branch and hand off with `complete_implement_step`. Both handoff paths require operator confirmation before dispatching automation. Once dispatched, the workflow owns grader repair with fresh workflow-agent turns; the original chat is only notified passively.

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

## visual_review

**Category:** Labs

Instance-wide default for the visual_review Labs feature: a headless-browser QA pass the worker agent runs against its own in-step preview to catch visible defects before opening a PR, capturing screenshot artifacts for operator review. When enabled instance-wide, a repository's `.syrus.yml` `visual_review.enabled` setting can still override the default per repo (and vice versa when disabled instance-wide). See the `visual_review` section of the `.syrus.yml` reference for the per-repo `rounds`, `when_files_changed`, and `seed_notes` fields.

## admin_supervisor_chat

**Category:** Operations

Enables one durable pinned Supervisor chat per admin user. The app admin API can open or provision the chat at `/api/v1/app/admin/supervisor_chat`; the endpoint returns `404` with `feature_disabled` while the flag is off and `403` for non-admins.

Supervisor chat identity is stored on `chat_sessions.system_kind = "supervisor"`, separate from the ordinary chat `mode` (`planning`, `coding`, `local`). A unique database index on `(user_id, system_kind)` enforces at most one Supervisor chat for each admin while allowing unlimited ordinary chats with `system_kind = NULL`.

While the flag is enabled, normal chat update paths cannot hide, delete, rename, or unpin the Supervisor chat. `SupervisorChat.ensure_for!(admin_user)` creates or repairs the affordance with title `Supervisor`, `pinned: true`, no repository attachment, and a populated `last_message_at`. It also idempotently seeds one canned user kickoff message and enqueues the initial `ChatTurnJob`, so opening or reprovisioning Supervisor starts operations triage without requiring the admin to type first and without duplicating kickoff turns. The chat index payload exposes it as top-level `supervisor_chat`, not inside ordinary repository/general groups, so the app shell can render it as the single pinned admin control room above normal chats. The Supervisor composer uses operations-focused placeholder text and hides ordinary chat mode controls; Supervisor remains planning-mode behavior and does not prompt admins to attach a repository unless the task itself requires code context.

Major operational events are also recorded in the Supervisor chat while the flag is enabled. `SupervisorEvents.publish!(kind:, severity:, subject:, repository:, job:, epic:, proposal:, workflow:, run:, pr_number:, actor:, summary:, details:, dedupe_key:)` creates one `ChatScopedEvent` per admin Supervisor chat and enqueues `ChatScopedEventEvaluatorJob` for each new scoped event. The same publisher also resolves ordinary chats that originated the referenced work through confirmed proposal lineage: materialized proposals, Jobs, Epics, a Job's Epic, Workflows/Runs via their Job, and pull request numbers that map back to a Job. Ordinary chats only receive scoped events for matching originated work; unrelated Job/Epic events and generic chat attachments are ignored. The event row stores the target chat, source kind, structured payload, optional repository/Job/Epic/proposal ids, delivery state, dedupe key, and disposable evaluator result fields. `ChatScopedEventEvaluatorJob` evaluates one scoped event for its target chat in an isolated temporary provider session. It clones persisted chat context, preferring the full transcript, and falls back to the latest 10,000 messages plus a byte cap for very large content/tool outputs. The evaluator receives read-only MCP tools plus the narrow `submit_scoped_event_decision` tool; Syrus prefers that structured tool result, falls back to strict JSON parsing, retries malformed parser output once, and only converts remaining parser failures to `no_op` for low-severity informational events. Critical and warning events still fail the evaluator for operator inspection. A `no_op` records the decision but creates no visible chat message and wakes no live turn. `respond` and `act` create an immediate real `ChatWakeup` whose user message contains the structured scoped event, evaluator decision, and handoff prompt; the live chat prompt explicitly tells the agent to read current Syrus state before acting on stale event data. The admin overview surfaces the evaluator pipeline for operators with recent scoped events, 24-hour `no_op`/`respond`/`act` counts, evaluator state counts, and recent failure reasons. A maintenance job automatically retries recent failed pending evaluator events, and already delivered actionable events are skipped on retry so visible wakeups are not duplicated. Publishing a scoped event still updates `last_message_at`, clears `last_read_at`, and broadcasts a chat update so the sidebar surfaces the event as unread even before any visible response exists. The index payload includes `supervisor_unread_count` and `supervisor_unread_severity` (`info`, `warning`, or `critical`) from unread Supervisor scoped events. The publisher no-ops completely while `admin_supervisor_chat` is disabled.

Supervisor agent turns receive the `chat:admin` role with a constrained Supervisor tool set: repository attachment, new-work drafting, work-delegation, recurring-work creation, and feedback-submission tools are not available. The Supervisor prompt directs the agent to treat `supervisor_event` system messages as operational context, summarize incidents, inspect live Syrus state, read current state before acting, and keep risky side effects behind pending-action confirmation. Missing repository attachment is normal for Supervisor operations triage; when code inspection or new implementation work is needed, Supervisor recommends the next step in prose for an ordinary planning surface instead of initiating it. Chat-history fallback preserves Supervisor event messages and pending-action outcome notices so provider resume failures do not drop the audit trail that motivated an action.

Initial event sources are existing notifications (`NotificationService`) for job failures, implemented Jobs, merged PRs, PR feedback completion, upstream PR closure, Epic completion, and main-branch health changes, plus `submit_insight` when an Agent Insight suggestion becomes available. Callers should pass stable `dedupe_key` values for poll-driven events; the service suppresses duplicate scoped events for the same target chat to prevent repeated poll loops from flooding admins.

## chat_context_compaction

**Category:** Operations

Compacts provider replay context for long-running Supervisor chats without
deleting or hiding any durable `ChatMessage` rows. The full chat remains visible
and auditable in the UI and searchable through normal chat/admin tools.

When enabled, `ChatTurnJob` creates a `ChatContextCheckpoint` once a Supervisor
chat has at least 120 messages. The checkpoint deterministically summarizes all
but the latest 40 messages, stores the summary and
`compacted_through_message_id`, and leaves the original messages untouched.
Provider rehydration then sends one synthetic "prior context summary" assistant
message followed by the recent raw messages after that checkpoint. This keeps
normal live turns from replaying huge old tool results forever while still
telling the agent to use tools if exact older details are needed.

This first implementation intentionally avoids an extra LLM summarizer call:
the summary is an extractive operational digest of older user/assistant/system
text, tool calls, and bounded tool-result snippets. It is only applied to
Supervisor chats; ordinary chats continue using their existing provider
transcript behavior even when the flag is on.

## landing_validation_prefetch

**Category:** Operations

Enables speculative landing validation for the next eligible same-repository
Job in the landing queue. After the current `auto_merge` workflow's landing
graders pass, Syrus may dispatch an infrastructure `landing_validation`
workflow for the next ordinary owned-branch PR. That workflow rebases the next
PR onto the predicted post-merge tree, runs the same fast landing graders, and
records a reusable landing-validation artifact.

Actual publication remains serialized: speculative validation never pushes,
never runs `landing_fix`, never calls the GitHub merge API, and never moves the
Job into `landing`. If the previous Job fails to land, or if the later real base
tree/grader configuration/changed-file selection differs, Syrus discards the
speculative result and the normal `auto_merge` workflow reruns graders. The flag
defaults to off because it spends grader capacity ahead of the queue and may
produce wasted work when the front Job fails.

## performance_logging

**Category:** Operations

Records structured slow-request, SQL query, and phase-timing events to logs and a short-lived admin diagnostics buffer. Useful for profiling production performance. No user-facing impact.

When enabled, Syrus emits:

- `syrus.performance.slow_request` for controller requests slower than `SYRUS_PERFORMANCE_SLOW_REQUEST_MS` (default 1000 ms), including request id, method, path, controller/action, status, current user id/admin flag when available, request SQL counts/duration, and the top SQL fingerprints observed during the request.
- `syrus.performance.slow_sql` for SQL statements slower than `SYRUS_PERFORMANCE_SLOW_SQL_MS` (default 250 ms), including request context, SQL name, a truncated SQL sample, duration, and a normalized fingerprint.
- `syrus.performance.slow_phase` for instrumented application phases slower than `SYRUS_PERFORMANCE_SLOW_PHASE_MS` (default 250 ms), including request context and sanitized metadata.
- `syrus.performance.browser_trace` for selected browser route loads, currently dashboard list loads, including sanitized route path, total browser-observed duration until current rows render, document visibility state, row counts, and the backend request ids/durations/statuses for the dashboard chrome and rows API calls. Browser traces intentionally omit row content, titles, prompts, and free-form filter text.

Request phase instrumentation covers complex app/admin payloads that are likely to become performance bottlenecks over time, including dashboard rows/chrome, smart folders, job detail, repository list/detail, chat open/index/message payloads, bootstrap/setup status, spending, and admin overview/queue payloads. The phase wrappers are gated by the feature check, so the disabled-path cost is intended to stay very low.

The admin performance endpoint returns the raw recent events plus grouped summaries for slow requests, slow phases, browser traces, and SQL fingerprints. Each event is stamped with `app_revision` from `SyrusVersion.current` / `GIT_SHA`; the admin payload defaults to the current revision so stale pre-deploy timings do not dominate post-deploy analysis, with an all-revisions mode available for rolling-deploy overlap debugging. The diagnostics buffer is kept in a per-process memory ring capped at 1,000 events and flushed opportunistically to `Rails.cache` under `syrus:performance_logging:events:v1` at most once every 10 seconds, with a 6-hour cache expiry. In production that cache flush uses the configured cache store (`solid_cache_store`), but slow-event emission does not write Solid Cache for every event. Browser diagnostics include explicit route/action traces plus global long-task, slow-input, and event-loop-lag samples while the feature is enabled. Events are also written to structured application logs, so external log retention follows the deployment's log sink policy.

When the `syrus_dev` plugin is enabled, Admin → Performance and the admin performance API expose the same diagnostics payload. Implementation workflow agents working on `tkadauke/syrus` or a registered fork whose upstream is `tkadauke/syrus` receive the read-only `read_performance_diagnostics` MCP tool through that plugin. Scheduled prompts that ask agents to improve Syrus performance can tell the agent to call this tool before changing code. It returns the same current-revision/all-revisions filtering semantics as the admin performance payload, plus bounded grouped slow-request, slow-phase, and SQL fingerprint summaries. Raw recent events are omitted unless `include_events` is true, still capped by `limit`, and sanitized to omit SQL samples, query strings, and obvious secret-bearing metadata.
