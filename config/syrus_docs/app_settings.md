# AppSetting Reference

`AppSetting` is a singleton configuration row for the Syrus instance. Read it with `AppSetting.current`; update via the admin UI or Rails console: `AppSetting.current.update!(key: value)`.

Typed metadata for these fields lives in `AppSettingRegistry`. Defaults, validation ranges, categories, operational meaning, and special `0` semantics should be changed there first so model validations, admin API metadata, and this reference stay aligned.

Reachability and scope decisions are recorded in
[`app_setting_scope_audit.md`](../../docs/engineering/conventions/app_setting_scope_audit.md). Use that audit when
deciding whether a new setting belongs in `AppSetting`, on `Repository`, or as
an instance-wide default with a future per-repository override.

## Workflow behavior

### grade_max_iterations

**Type:** integer · **Default:** 5 · **Range:** 1–10

Maximum number of repair→check cycles in the grader loop before a workflow fails. Per-repo `.syrus.yml` can override this with `grade.max_iterations`.

### adversarial_review_rounds

**Type:** integer · **Default:** 0 · **Range:** 0–10

Number of implement→adversarial-review iterations run before graders. `0` disables adversarial review instance-wide. Per-repo `.syrus.yml` can override with `adversarial_review.rounds`.

### security_review_rounds

**Type:** integer · **Default:** 0 · **Range:** 0–10

Number of implement→security-review iterations run after adversarial review and
before graders. `0` disables security review instance-wide. Per-repo
`.syrus.yml` can override the round count with `security_review.rounds` and add
repository-specific guidance with `security_review.criteria`.

Visual review is on by default instance-wide with no `AppSetting` or Feature
flag controlling it — only a repository's `.syrus.yml` can override it — see
[`visual_review.md`](visual_review.md) and [`feature_flags.md`](feature_flags.md).

### max_job_failures

**Type:** integer · **Default:** 3 · **Min:** 1

Consecutive failure threshold. When a ScheduledTask accumulates this many consecutive failures it auto-pauses (state `auto_paused`). Also used as the retry budget ceiling for Job auto-close after repeated failures.

### main_concern_report_threshold

**Type:** integer · **Default:** 2 · **Min:** 1

Minimum number of repeated broken-main reports before the aggregator surfaces a main-branch concern.

### merge_train_failure_policy

**Type:** string · **Default:** `restart` · **Options:** `restart`, `keep_assembly`, `keep_fixes`

Compatibility default for what happens to an assembled merge train when its
workflow fails. Repositories should declare their ordered escalation ladder in
default-branch `.syrus.yml` under `merge_train.failure_policy`; this instance
setting is used only when that repository config is confirmed absent,
preserving the previous instance-wide behavior across retry attempts. If the
repository config exists but cannot be parsed or read, Syrus uses the
conservative `restart` behavior rather than guessing from this instance
default.

`restart` is the historical behaviour: the train is terminalized, its
integration branch is deleted, and every member is handed back to
`LandingFailureHandler` individually — transient blockers defer and stay
approved, genuine failures revert to `implemented` and need re-approval. The
next attempt re-derives its membership from the approved pool and regrades
from scratch, so a train of a dozen Jobs stopped by one infrastructure
failure discards the whole assembly.

`keep_assembly` leaves the train and its integration branch intact **when the
failed run was classified retryable** — a worker death, a rate limit, a disk
or database capacity problem — so the retry reuses what was already
assembled instead of rebuilding it. A failure attributable to a member's own
code still tears the train down under this policy; preserving the assembly
around a real defect would wedge the train on it indefinitely. An
unclassifiable failure is treated as attributable, which keeps the behaviour
conservative.

This is the same preservation the continuation-retry path already performs,
widened to any retryable failure.

`keep_fixes` runs the same assembly-preservation rung first for ordinary
retryable failures. When the failure is explicitly rebuild-required, especially
when the base branch moved, Syrus terminalizes the stale train but leaves its
integration branch available for the replacement train. The replacement train
rebuilds every member on the current base and, if the member set is identical,
cherry-picks the previous integration branch commits that were not recorded as
member work. If a repair cherry-pick conflicts, Syrus aborts the replay, resets
the rebuilt assembly to its pre-replay tip, and continues without the old fixes
so a half-applied repair branch is never published.

When a repository configures a `.syrus.yml` ladder, attempt 1 uses the first
rung, attempt 2 the second, and so on. Attempts past the end of the list fall
back to `restart`. Unknown rung names are skipped so repositories can name
future rungs before the Syrus instance implements them. The walk is capped by
the same automatic retry budget used by the WorkEngine repair planner, so a
repeatedly failing train cannot climb forever.

Splitting a failed train — landing the clean members while the rest re-train
— is not offered. It needs a rule for attributing a failure to a particular
member, and an unattributable failure would split the train arbitrarily.

### merge_train_max_size

**Type:** integer · **Default:** 20 · **Min:** 1

Maximum number of unrelated PRs that can participate in a single job-bundle train. Applies to epicless job bundles only: the assembler trims the ordered candidate list to this size without separating a dependent from its prerequisite.

Epic trains are **not** capped. Their children are a linear stack rather than unrelated changes, and an Epic lands all-or-nothing, so a cap could only refuse it outright. See `merge_train.md`.

### merge_train_multisect_section_width

**Type:** integer · **Default:** 4 · **Range:** 2–16

Number of sections used per round by the focused merge-train multisect attribution rung. Wider values spend more concurrent focused grades and subset builds per round to reduce wall-clock rounds, so raise this only when the instance has enough spare worker capacity.

## Instance operations

### ui_engagement_telemetry_enabled

**Type:** boolean · **Default:** false

Opts the instance into per-user active/visible-time collection on allowlisted
Job, PR-review, and chat pages. Active time excludes hidden tabs and stops after
60 seconds without input. Samples are retained for 90 days.

### signups_open

**Type:** boolean · **Default:** false

Allow new user registrations. Set to `false` on private instances.

### beta_mode_enabled

**Type:** boolean · **Default:** false

Instance-level opt-in that allows admins to explicitly enable beta or
experimental capabilities, such as beta feature flags and experimental bundled
plugins. Turning on beta mode does not enable any feature or plugin by itself.

### polling_paused

**Type:** boolean · **Default:** false

Emergency kill switch: pause all polling jobs (`PollAllRepositoriesJob`, `PollAllPullRequestsJob`, etc.). Jobs already running complete normally; no new issues or PR comments are picked up.

Repository issue polling also backs off automatically when the relevant
GitHub credential is rate-limited: the fan-out skips already-exhausted
repositories, and an in-flight autonomous repository poll that receives
`Octokit::TooManyRequests` re-enqueues after GitHub's reset time without
advancing the repository poll watermark.

### repository_full_poll_interval_hours

**Type:** integer · **Default:** 24

Maximum age, in hours, of a repository's last successful full issue poll.
Normal repository issue polls use GitHub's `since` cursor for incremental
reads, but GitHub filters that cursor by issue `updated_at`, not by the time a
label was applied. When this interval has elapsed, the next autonomous
repository issue poll omits the cursor and reconciles all open trigger-labeled
issues. A successful full poll stamps `Repository#last_full_poll_at`.

Full reconciles still use the same linked-PR lookup budget as incremental
polls. If a large backlog exceeds that per-poll budget, Syrus defers the
overflow and does not advance either poll watermark; later polls continue the
reconcile in bounded chunks instead of spending one oversized GitHub burst.

### runs_paused

**Type:** boolean · **Default:** false

Emergency kill switch: pause workflow execution. `RunJob` checks this flag and re-enqueues itself if true, so active Runs stay queued without losing state.

### report_issue_repo_slug

**Type:** string · **Default:** "tkadauke/syrus"

Controls where in-app bug reports are sent. The slug is also used for the "Report an issue" link displayed in the UI.
The setting is required; saving a blank value is rejected.

**Routing logic:** when a user submits a bug report, Syrus checks whether an active `Repository` record exists for this slug (system-wide match) or whether the user has a fork of it (`upstream_owner`/`upstream_name` match). If either is found, the report is filed as a direct Syrus Job against that repository. If neither is found, the report is filed as a plain GitHub issue via the API using the user's PAT; screenshots and attachments are uploaded to GitHub's asset CDN and embedded inline in the issue body.

On self-hosted instances, set this to the `owner/name` of your own Syrus fork. If the fork is tracked in Syrus as a repository, reports will be routed as Jobs; if not, they will be filed as GitHub issues against that slug.

### max_concurrent_agent_runs

**Type:** integer · **Default:** 3 · `0` = unlimited

Global, cluster-wide cap on how many `:runs` queue Runs execute at once, across **all** worker pods. `RunJob` enforces it with a best-effort defer-and-re-enqueue gate (DB-counted, so it holds across pods). Set this when running multiple worker pods so total compute concurrency — and Claude/Codex cost and rate-limit exposure — does not scale with pod count; each pod's `JOB_CONCURRENCY` only bounds that single pod. `0` means no global cap. Main-branch grader Runs are on `:runs` and are counted; landing/merge Runs (`:merges` queue) are not counted, so they can't be starved by a saturated agent cap.

This soft cap is enforced only when `workflow_admission_control_enabled` is
enabled.

### prepared_layer_cache_gb

**Type:** integer · **Default:** 10 · `0` = no size budget

Disk budget, in GB, for each worker's cache of prepared workspace trees -- the
trees grader checkouts are materialized from. `SYRUS_PREPARED_LAYER_CACHE_GB`
overrides it on an individual worker, which is the point of having both: a
256 GB laptop worker and a 1 TB server should not be told the same number.
Each worker records its effective value and source with host-health telemetry;
Admin → Retention & Storage shows those worker-attributed reports separately
from the instance default.

Implementation and eviction mechanics are documented in the [app-setting architecture reference](../../docs/engineering/architecture/app-settings.md).

### max_in_flight_workflows

**Type:** integer · **Default:** 0 · `0` = unlimited

Cap on how many Job workflow attempts may be admitted and unfinished at once,
instance-wide. `WorkflowAdmissionBudget` checks it when an attempt is **first**
admitted and answers `delay_until` with reason `in_flight_workflow_limit` once
that many are already running; the attempt stays queued and is reconsidered
after the soft delay. This soft limit is active only when
`workflow_admission_control_enabled` is enabled.

The limit paces starts so that some attempts finish before more begin. Without
it a burst of filed Jobs can each reach a prepared workspace and then sit
mid-pipeline, holding disk on the hosts the remaining steps still need.

What it deliberately does **not** do:

- It never applies to work already in flight. A phase boundary of an admitted
  workflow, and every grader it fans out across the fleet, pass without
  consulting it — the limit exists to pace starts, not to add friction to work
  in progress.
- Landing, main-branch health and repair workflows are exempt and do not count
  toward it: those drain and unblock the queue the limit is protecting.
- A workflow stops counting the moment it reaches a terminal state, whatever
  workspace is still on disk behind it. Workspace retention is a separate
  concern (`WorkflowWorkspacePruneJob`).
- Urgent-priority Jobs are admitted past it.

Like the global agent-run cap this is best-effort: a burst admitted inside the
same moment can overshoot by a few before any of them reaches `running`. A
reasonable starting point is a small multiple of the fleet's concurrent agent
capacity — enough to keep every host fed and pipelined, not enough to leave
dozens of half-finished attempts parked.

## GitHub App

### github_app_id

**Type:** bigint

The numeric ID of the registered GitHub App. Set once during GitHub App setup via the admin UI.

### github_app_private_key_pem

**Type:** text (encrypted)

The RSA private key PEM for the GitHub App. Used to sign JWT tokens for App authentication. Stored encrypted via Active Record Encryption.

### github_app_slug

**Type:** string

The URL slug of the GitHub App (appears in `https://github.com/apps/<slug>`).

### workflow_admission_control_enabled

**Type:** boolean · **Default:** `false`

Master switch for optional soft capacity pacing. Enable it on busy shared,
multi-user instances to apply workflow-level pressure and in-flight limits,
host-local background yielding, compute/memory reservations and start
staggering, the global agent-run cap, and per-actor fair share. A fresh
single-host or Docker Compose install needs no admission tuning by default.

The switch does not disable hard worker memory/disk or critical local-pressure
protection. Provider-availability pauses, manual
pauses, dependencies, and landing-queue correctness gates also remain active.
Changing the switch does not rewrite any other setting or existing record.

### host_admission_policy

**Type:** string (`prediction` or `usage`)

Controls how an individual worker decides it has room for another Run. This is
separate from `workflow_admission_policy`, which governs how far a *Workflow*
level admission decision extends.

See the [app-setting architecture reference](../../docs/engineering/architecture/app-settings.md) for resource-profile and PSI mechanics.

### workflow_admission_policy

**Type:** string (`whole_workflow` or `phase_aware`)

Controls how `WorkflowAdmissionBudget` applies after a Workflow has started.
`whole_workflow` is the default: admission happens before start and the
Workflow keeps advancing through normal phase boundaries once admitted.
`phase_aware` keeps the tighter optimizer and may pause between phases when
predicted pressure is high. Hard worker memory/disk exhaustion can pause an
in-flight Workflow under either policy; paused Workflows keep their persisted
state but expose an apparent `paused` state in the dashboard.

## Video walkthroughs

These two settings belong to the bundled `video_walkthroughs` plugin and only
do anything while it is enabled. They live in the core settings registry
alongside the Discord plugin's token, because plugin-owned `AppSetting`
definitions do not have a home of their own yet.

### video_retention_days

**Type:** integer · **Default:** 7 · **Min:** 1

How long to retain walkthrough video blobs before `VideoWalkthroughs::PruneJob` deletes them. The analysis and screenshots persist indefinitely; only the raw video blob is pruned.

### video_storage_budget_mb

**Type:** integer · **Default:** 2048 (2 GB) · `0` = unlimited

Instance-wide storage budget for walkthrough video blobs, measured in megabytes. When the budget is exceeded, `VideoWalkthroughs::PruneJob` evicts the oldest blobs first (LRU). The class method `AppSetting.video_storage_budget_bytes` converts this to bytes for internal use.

## External platform integrations

### telegram_bot_handle

**Type:** string · **Default:** nil

The `@handle` of the Syrus Telegram bot (e.g. `syrus_bot`). Setting this marks Telegram as configured; `AppSetting.telegram_configured?` returns true and the Connected Platforms UI shows Telegram as available. Saving a blank handle clears the setting and disables Telegram configuration. The Telegram integration itself (long-poll adapter) is a separate job that registers via `PlatformPollingJob.registry`; this setting is what that job checks in its `configured?` guard.

### discord_bot_token

**Type:** string (encrypted) · **Default:** nil

The bot token used by the `discord` plugin's Gateway connector (`Discord::GatewayConnectionJob`) and outbound adapter (`Discord::PlatformAdapter`). `AppSetting.discord_bot_token` is the gate `Discord::GatewayConnectionJob#configured?` checks before opening a Gateway connection; it is separate from the `discord` `PluginRecord`'s install/enable toggle -- the plugin can be enabled with no token set (no connector starts) or disabled with a token already configured.

## Coding-Mode workspaces

### chat_coding_workspace_budget_mb

**Type:** integer · **Default:** 10240 (10 GB) · `0` = disabled

Instance-wide byte budget for retained Coding-Mode chat checkouts (each is a writable full clone plus installed dependencies, commonly 1–2 GB), measured in megabytes. When retained checkouts exceed the budget, `WorkflowWorkspacePruneJob` calls `ChatWorkspace.reclaim_coding_over_budget!` to LRU-evict the least-recently-active ones until total on-disk size is under budget — after safely backing up any un-pushed / uncommitted work to the remote (see the Coding Mode docs). Fresh installations default to 10 GB. `0` disables the size cap; the idle-reclaim window (`ChatWorkspace::RECLAIM_IDLE_CODING_AFTER`, 48 h) and reclaim-on-handoff still apply. Existing installations retain their stored value. `AppSetting.chat_coding_workspace_budget_bytes` converts it to bytes.

## Data retention

Retention is configured on **Admin → Retention Settings**. Detailed sweep,
archive, pruning, and extension-point mechanics live in the
[data-retention operations guide](../../docs/engineering/operations/data-retention.md).

| Setting | Default |
| --- | ---: |
| `draft_visual_evidence_retention_days` | 7 days |
| `job_log_retention_days` | 30 days |
| `performance_log_event_retention_hours` | 24 hours |
| `run_diagnostic_retention_days` | 30 days |
| `run_resource_summary_retention_days` | 30 days |
| `workspace_reuse_outcome_retention_days` | 90 days |
| `worker_host_health_sample_retention_days` | 7 days |
| `work_engine_reconciler_activity_retention_days` | 7 days |
| `provider_session_retention_days` | 14 days |
| `spawned_process_retention_days` | 7 days |
| `notification_retention_days` | 30 days |
| `operational_log_event_retention_hours` | 6 hours |
| `run_health_snapshot_retention_days` | 7 days |
| `main_branch_health_check_retention_days` | 7 days |
| `workflow_step_resource_profile_retention_days` | 180 days |

`job_log_retention_days` controls the detailed output shown for a Run. After
the default 30-day window, stdout, stderr, tool-call, and system chunks are
deleted while the Run and its other history remain. Enable
`job_log_archive_before_delete` before pruning if that detailed output must be
preserved outside the live table. `performance_log_event_retention_hours` is a
short diagnostic window; its default remains the 24 hours used by the
performance UI.

`provider_sessions` is large primarily because each row can contain a provider
transcript (`transcript_jsonl` is a 64 MiB-capable text column), not because of
its metadata. For terminal Runs, the generic retention sweep clears `transcript_jsonl` and
`normalized_messages` after seven days while retaining lightweight session
metadata, then deletes the whole row after the configurable window (14 days by
default). Both phases run in bounded batches and use the
`(resumable_type, updated_at, resumable_id)` index, so finding candidates does
not scan payload values. Clearing or deleting payloads frees pages for InnoDB
reuse, although InnoDB does not necessarily return the physical tablespace
file to the operating system. Active Run sessions remain protected because
they can still be resumed. Enabling `provider_session_archive_before_delete`
also disables the early payload clearing phase so the eventual archive still
contains the transcript and normalized messages.
