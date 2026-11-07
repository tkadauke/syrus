# Feature flags

## Hidden flags

No feature flags are currently hidden from Admin → Features. `Api::V1::App::Admin::FeaturesController::ALWAYS_HIDDEN_SLUGS` is reserved only for declared-but-unfinished flags that must remain console-only while they are unsafe or misleading as self-hoster-facing toggles.

A hidden flag must default to `false`. The moment a flag is code-complete enough to default on, or otherwise becomes an operator-supported escape hatch, remove it from `ALWAYS_HIDDEN_SLUGS` in the same change. The feature registry spec enforces this by rejecting any slug that is both hidden and declared `default: true` in `config/features.yml`; hidden-and-off remains valid for unfinished work.

## grader_fanout_overlay

**Category:** Operations · **Off by default**

Mounts local overlayfs workspaces for immutable grader checkouts when the worker supports it. The prepared checkout remains the read-only lower directory, while each materialized grader gets its own thin upper/work directories and mountpoint under the workflow workspace. This avoids copying large prepared dependencies such as `vendor/bundle` and `node_modules` for every grader.

Syrus checks for Linux and kernel overlayfs support before attempting the mount. A mount failure, an unsupported filesystem, or a non-Linux worker falls back to a **hardlinked** materialization of the same prepared tree, and only to a full byte copy if the filesystem also refuses links. Workflow cleanup unmounts overlay workspaces before removing the workflow directory.

Note that an unprivileged container cannot mount overlayfs: the mount is
refused with `must be superuser to use mount` unless the worker holds an
effective `CAP_SYS_ADMIN`, so on a stock Kubernetes worker this flag records a
fallback rather than mounting anything.

Support is probed once per process rather than attempted per materialization,
because the old check -- Linux, plus `overlay` in `/proc/filesystems` -- could
not see the missing capability and so logged a failed mount every time
(2,232 of them in one production day). The probe also reports whether a mount
**inside a user namespace** would succeed, which is what a stock worker can
do on kernels 5.11 and newer (`unshare --user --map-root-user --mount
--propagation unchanged`; the default `private` remount of `/` is itself
privileged). Nothing uses that strategy yet: such a mount exists only inside
the namespace, so the graded command would have to execute there too, which is
a change to how commands are run rather than how workspaces are materialized.
The fallback log says when a host is ready for it.

### Host requirements and diagnosing a fallback

Overlay mounts only work when the worker host satisfies all of:

- **Linux** with `overlay` listed in `/proc/filesystems`.
- **Privileges**: either an effective `CAP_SYS_ADMIN` (direct mount), or kernel 5.11+ with unprivileged user namespaces enabled (`/proc/sys/user/max_user_namespaces` above 0, `kernel.unprivileged_userns_clone` not 0, and no AppArmor/seccomp profile blocking `unshare`). Only the direct mount is used today.
- **Filesystem**: the workspace root must be a filesystem that can host overlay upper/work directories (not itself an overlayfs that refuses nesting).
- `mount` and `unshare` binaries on `PATH`.

When overlay is unavailable, **hardlink fan-out is the effective default**, and it already costs about zero extra bytes. So an instance with this flag on but overlay unavailable is working as designed, not broken.

To see why a worker cannot mount: the worker's capability diagnostics (worker health) carry an `overlayfs` entry with the strategy, a reason naming the blocking cause, and per-attempt command, exit status and stderr plus the environment facts (effective uid, `CAP_SYS_ADMIN`, user-namespace limits, filesystem types, `mount`/`unshare` availability). Each grader Step that fell back also records `overlay_capability` and `overlay_diagnostics` in its `immutable_source_workspace` details.

### Materialization strategies

Each grader's checkout is materialized from the prepared tree -- a complete
checkout, dependencies included, untarred once per workflow, source SHA and
prepare fingerprint on that worker. The strategy used is recorded in the
grader step's and Run's `immutable_source_workspace` details, with the reason
each earlier strategy was skipped:

| strategy | how | cost on a ~1.6 GB / 69k-entry checkout |
| --- | --- | --- |
| `overlay` | the prepared tree as a read-only lower, a private upper per grader | mount, no data movement |
| `hardlink` | one hard link per file, so the bytes are shared | ~2 seconds |
| `copy` | a full recursive byte copy | 3-25 minutes, depending on how many siblings in the fanout are copying at once |

The hardlink strategy gives each checkout a private copy of the paths a graded
run writes **in place**, because the prepared tree is shared by every grader on
the host: `.git` (a working tree's index, reflogs and packed-refs are rewritten
by ordinary git commands), `.bundle`, `.syrus`, `Gemfile.lock`, the JavaScript
lockfiles, `app/assets/builds`, `coverage`, `db`, `log`, `storage` and `tmp`.
Everything else -- `node_modules` and `vendor` are 71% of the bytes -- is
shared, which is safe because git, bundler and npm write a new file and rename
it over the old name rather than editing in place.

## chat_context_compaction

**Category:** Operations · **Beta/experimental**

**Currently has no effect.** `ChatContextCompactor#enabled_for_chat?` is
hard-coded to `false`: this flag's only consumer was the admin Supervisor
chat, and that feature has been removed. Toggling it on does not compact any
chat today. The algorithm below is retained (and still fully unit-tested)
pending a decision on whether to generalize it to ordinary chats or delete it
outright — do not rely on this flag doing anything in the meantime.

Compacts provider replay context for a chat without
deleting or hiding any durable `ChatMessage` rows. The full chat remains visible
and auditable in the UI and searchable through normal chat/admin tools.

If re-enabled, `ChatTurnJob` would create a `ChatContextCheckpoint` once a
chat has at least 120 messages. The checkpoint deterministically summarizes all
but the latest 40 messages, stores the summary and
`compacted_through_message_id`, and leaves the original messages untouched.
Provider rehydration then sends one synthetic "prior context summary" assistant
message followed by the recent raw messages after that checkpoint. This keeps
normal live turns from replaying huge old tool results forever while still
telling the agent to use tools if exact older details are needed.

This first implementation intentionally avoids an extra LLM summarizer call:
the summary is an extractive operational digest of older user/assistant/system
text, tool calls, and bounded tool-result snippets.

**Observability:** every actual compaction run (a new `ChatContextCheckpoint` is
created) emits an `OperationalLogging` event with `source: "chat_context_compactor"`,
queryable through the `admin_read_operational_logs` MCP tool (or
`read_syrus_logs` for workflow/insight agents) when `operational_log_indexing`
is on. The event's `context` records the chat session id and checkpoint id,
how many messages were compacted this run vs. the cumulative total, how many
raw messages remain uncompacted, an estimated JSON byte size for the compacted
vs. kept content, and timing (`session_age_seconds`,
`seconds_since_previous_checkpoint`) so an operator can judge how often
compaction fires relative to a chat's age and length. This is intentionally
just enough evidence to decide whether the extractive summary is pulling its
weight or whether a real LLM-summarizer pass is worth building — not a
dashboard. The same payload is also broadcast via
`ActiveSupport::Notifications` as `chat_context_compactor.compacted` for local
inspection. Recording these metrics is best-effort: a failure there is caught
and logged as a warning rather than propagated, so it can never take down the
chat turn that triggered compaction — the checkpoint it reports on has
already persisted by the time metrics are recorded.

## performance_logging

**Category:** Operations

Records structured slow-request, SQL query, and phase-timing events to logs and a short-lived admin diagnostics buffer. Useful for profiling production performance. No user-facing impact.

When enabled, Syrus emits:

- `syrus.performance.slow_request` for controller requests slower than `SYRUS_PERFORMANCE_SLOW_REQUEST_MS` (default 1000 ms), or requests that stay below that wall-clock threshold but still cross `SYRUS_PERFORMANCE_REQUEST_SQL_COUNT_THRESHOLD` (default 50 queries) or `SYRUS_PERFORMANCE_REQUEST_SQL_DURATION_MS` (default 500 ms of SQL time). Events include trigger reasons, request id, method, path, controller/action, status, current user id/admin flag when available, request SQL counts/duration, and the top SQL fingerprints observed during the request.
- `syrus.performance.slow_sql` for SQL statements slower than `SYRUS_PERFORMANCE_SLOW_SQL_MS` (default 250 ms), including request context, SQL name, a truncated SQL sample, duration, and a normalized fingerprint.
- `syrus.performance.slow_phase` for instrumented application phases slower than `SYRUS_PERFORMANCE_SLOW_PHASE_MS` (default 250 ms), including request context, sanitized metadata, total SQL counters/fingerprints across nested child phases, and self SQL counters/fingerprints for SQL issued directly inside that phase.
- `syrus.performance.browser_trace` for selected browser route loads, currently dashboard list loads, including sanitized route path, total browser-observed duration until current rows render, document visibility state, row counts, and the backend request ids/durations/statuses for the dashboard chrome and rows API calls. Browser traces intentionally omit row content, titles, prompts, and free-form filter text.
- `syrus.performance.memory_high_water` when an Active Job worker process crosses a new 256 MiB RSS/container-memory bucket or 70%, 80%, or 90% of its cgroup limit. A single one-second sampler records process RSS, container memory and OOM counters, Ruby heap live slots, every active job context, and jobs that joined since the preceding bucket. These sparse crossing events bypass the in-memory observability buffer and are inserted synchronously, so the evidence survives if the worker is killed before normal flushing.
- `syrus.performance.job_memory_summary` on normal job completion, with the job's start, end, and peak process/container memory readings. Since a worker process can execute concurrent jobs, these records attribute the complete active set rather than claiming that shared Ruby heap memory belongs to one job. Separate queue-pool processes still share the same container reading, making cross-process container pressure visible without conflating it with per-process RSS.

Request phase instrumentation covers complex app/admin payloads that are likely to become performance bottlenecks over time, including dashboard rows/chrome, smart folders, job detail, repository list/detail, chat open/index/message payloads, bootstrap/setup status, spending, and admin overview/queue payloads. The phase wrappers are gated by the feature check, so the disabled-path cost is intended to stay very low.

The admin performance endpoint returns the raw recent events plus grouped summaries for slow requests, slow phases, browser traces, and SQL fingerprints. Each event is stamped with `app_revision` from `SyrusVersion.current` / `GIT_SHA`; the admin payload defaults to the current revision so stale pre-deploy timings do not dominate post-deploy analysis, with an all-revisions mode available for rolling-deploy overlap debugging. Slow-event emission writes structured JSON to `Rails.logger` and appends to the shared observability sink's per-process memory ring; it does not write Solid Cache. A lazy per-process background flusher drains each web/worker/sidecar process into the append-only `performance_log_events` table in batches, `FlushObservabilityEventsJob` provides a scheduled backstop, and the admin endpoint also flushes local pending events before reading so very recent samples are visible. The table retains 24 hours of events; the performance in-memory ring defaults to 2,000 events per process and is best-effort across process restarts. Browser diagnostics include explicit route/action traces plus global long-task, slow-input, and event-loop-lag samples while the feature is enabled. Events are also written to structured application logs, so external log retention follows the deployment's log sink policy.

When the `syrus_dev` plugin is enabled, Admin → Performance and the admin performance API expose the same diagnostics payload. The slow-request table can drill into retained request events and show matching slow phases plus the bounded top SQL fingerprints captured for both the request and each phase; these samples are capped and are diagnostic context, not an exhaustive query log. The SQL tab includes an Explain action for captured SQL samples. It opens a modal with a visual query-plan view, raw EXPLAIN rows, raw JSON, and normalized SQL. The backend endpoint is `POST /api/v1/app/admin/performance/explain` or `POST /api/v1/admin/performance/explain`; it accepts a single read-only SELECT/CTE statement, substitutes `?` bind placeholders with `NULL`, rejects comments/multiple statements/write statements, and returns whether `EXPLAIN ANALYZE` is safe. Analyze is intentionally conservative: it is MySQL-only, must be read-only, rejects user variables, and runs with a short statement timeout because it executes the query.

Implementation workflow agents working on `tkadauke/syrus` or a registered fork whose upstream is `tkadauke/syrus` receive the read-only `read_performance_diagnostics` MCP tool through that plugin. Scheduled prompts that ask agents to improve Syrus performance can tell the agent to call this tool before changing code. It returns the same current-revision/all-revisions filtering semantics as the admin performance payload, plus bounded grouped slow-request, slow-phase, browser-trace, and SQL fingerprint summaries. The payload also includes a current-deploy versus previous-retained-deploy baseline comparison so agents can focus on regressions instead of stale slow paths. Raw recent events are omitted unless `include_events` is true, still capped by `limit`, and sanitized to omit SQL samples, query strings, and obvious secret-bearing metadata.

## execution_request_assertions

**Category:** Operations

Checks local `ProcessRunner` executions against their declared execution request before container execution backends depend on that contract. `ProcessRunner` callers declare a `mounts:` structure containing a `workdir`, read-write mounts, optional read-only mounts, and an optional artifacts mount. They also declare a `network:` profile: `grader` for localhost-only validation commands, `prepare` for dependency installation/package-registry access, `agent` for agent CLIs and model/GitHub access, and `git_fetch` for git remote egress. The local backend still runs the command directly on the host filesystem; this flag only enables assertion checks.

When enabled, local execution requires `strace`. Syrus wraps the subprocess, records filesystem and network syscalls, and fails the command if it writes through a read-only declaration, writes outside declared writable mounts, touches another Syrus data-root path that was not declared, or if a `grader` command connects to a non-loopback address. Broader network profiles are declaration-only in the local backend until a container backend can enforce allowlists. The flag defaults off so assertion gaps cannot break existing local-mode installs while the execution request contract is being hardened.

## operational_log_indexing

**Category:** Operations

Indexes short-lived structured Rails application log events so Syrus implementation agents can search their own instance's recent logs while working on Syrus itself. `OperationalLogging.enabled_for_instance?` requires both the flag and at least one registered repository recognized as the Syrus repository itself (slug or upstream slug `tkadauke/syrus`, case-insensitive) — the feature never activates for ordinary target repositories. When both conditions hold, `ActiveSupport::Notifications` subscribers on `process_action.action_controller` and `perform.active_job` ingest structured request/job events into `OperationalLogIndex`/`OperationalLogEvent`, redacting secret-shaped values before storage. Jobs may add safe diagnostic identifiers through `ApplicationJob#operational_log_context`; maintenance-task runs include their task ID so sustained backfills can be distinguished from runaway scheduling without indexing arbitrary job arguments.

The `read_syrus_logs` MCP tool (bundled in the `syrus_dev` plugin) exposes search over this index, but only to workflow agents in the `workflow_implement` or `agent_insight` roles working on a recognized Syrus repository, and only while the flag and the repository check both pass; there's a matching admin-chat tool for admin use. Indexed events are retained 6 hours (`OperationalLogEvent::RETENTION`) and pruned by a recurring job. `SYRUS_OPERATIONAL_LOG_ACTIVE_JOB_SUCCESS_MIN_DURATION_MS` (default 1000 ms) suppresses noisy fast successful job events from ingestion. Off by default; only useful when running (or forked from) `tkadauke/syrus` itself.

Expected workflow outcomes such as `Steps::Base::StepFailed` remain searchable at `info` severity and include `expected_failure` context; unexpected Active Job exceptions are indexed at `error`. This keeps failed implementations and graders visible without mixing them into searches for Syrus platform failures.

## browser_error_auto_reports

**Category:** Operations

Automatically files one bug-report Job per unique browser-error fingerprint and app revision, so a recurring frontend error becomes a tracked Job instead of a silent log line. `BrowserErrorEvent` rows (client-reported, 14-day retention) enqueue `BrowserErrorAutoReportJob` on creation when the flag is enabled; the job claims a `BrowserErrorAutoReport` row guarded by a database-level unique index on `(fingerprint, app_revision)`, so duplicate events for the same error on the same revision silently no-op via `ActiveRecord::RecordNotUnique` rather than filing repeat Jobs.

On a successful claim, the report routes through `Observability::EventJobFiler` / `BugReports::Router`, producing a Job titled `Fix browser error: <message>` with a Markdown description embedding the event id, path, route, app revision, fingerprint, and full JSON payload; the report record is updated to `status: "reported"` with the resulting Job/issue URL, or `status: "failed"` with the error. Filing permission (`EventJobFiler#permitted?`) requires the acting user to be an admin or the original event's owner. No dedicated env vars or `AppSetting` fields — dedup is purely the fingerprint/revision unique index. Off by default.

## per_spawn_resource_limits

**Category:** Operations · **Off by default**

Enables adaptive cgroup v2 memory ceilings for subprocesses launched through
`ProcessRunner`. When enabled, each `SpawnedProcess` records a
`resource_attribution.cgroup` payload showing whether enforcement was applied,
disabled, unavailable, or failed. That payload is intentionally loud:
diagnostics can tell the operator that a command ran with no memory ceiling
instead of implying containment from the feature flag alone. A recorded
`memory.events` `oom_kill` increment is classified as
`process_memory_limit_exceeded`.

The default memory ceiling is derived from the worker pod's effective cgroup
memory limit rather than a fleet-wide fixed number. Syrus reserves memory for
the Rails/Solid Queue supervisor and filesystem overhead, then divides the
remaining memory by the current concurrency slots and multiplies by the run's
admission units. Agentic subprocesses default to
`SYRUS_AGENTIC_CAPACITY_UNITS` (2) and grader subprocesses default to
`SYRUS_GRADER_CAPACITY_UNITS` (1), matching the host-admission vocabulary.
Operators can still force exact bytes with `SYRUS_SPAWN_MEMORY_MAX_BYTES`,
`SYRUS_SPAWN_MEMORY_HIGH_BYTES`, and `SYRUS_SPAWN_MEMORY_SWAP_MAX_BYTES`, or
tune reserves with `SYRUS_SPAWN_RAILS_RESERVED_BYTES` and
`SYRUS_SPAWN_FILESYSTEM_RESERVED_BYTES`.

Delegation is checked before a subprocess starts. If the worker container
cannot create child cgroups with the memory controller, the cgroup payload is
recorded as `state: "unavailable"` with a delegation reason; Syrus does not
pretend a limit was applied. Bare-metal macOS development is the same explicit
no-enforcement mode (`no cgroup enforcement available ... outside a Linux
container`). The Electron docker-compose worker still runs inside Linux, so it
can enforce cgroups when the container runtime delegates them.

Per-spawn cgroups do not replace the checkout/fan-out filesystem fix. Page
cache is charged to the cgroup that first faults the page in, so worker-side
copies before the command starts can remain pod-level pressure rather than
child-cgroup usage. Both controls are needed: cgroups bound the spawned
process tree, while the checkout/fan-out fix removes avoidable pod pressure.


The operator-facing flag behavior remains in [`config/syrus_docs/feature_flags.md`](../../../config/syrus_docs/feature_flags.md).
