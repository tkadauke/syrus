# AppSetting Reference

`AppSetting` is a singleton configuration row for the Syrus instance. Read it with `AppSetting.current`; update via the admin UI or Rails console: `AppSetting.current.update!(key: value)`.

Typed metadata for these fields lives in `AppSettingRegistry`. Defaults, validation ranges, categories, operational meaning, and special `0` semantics should be changed there first so model validations, admin API metadata, and this reference stay aligned.

## Workflow behavior

### grade_max_iterations

**Type:** integer · **Default:** 5 · **Range:** 1–10

Maximum number of repair→check cycles in the grader loop before a workflow fails. Per-repo `.syrus.yml` can override this with `grade.max_iterations`.

### adversarial_review_rounds

**Type:** integer · **Default:** 0 · **Range:** 0–10

Number of implement→adversarial-review iterations run before graders. `0` disables adversarial review instance-wide. Per-repo `.syrus.yml` can override with `adversarial_review.rounds`.

Visual review's instance-wide default is controlled by the `visual_review` Labs
feature flag (`Feature.visual_review_enabled?`), not an `AppSetting` — see
[`visual_review.md`](visual_review.md) and [`feature_flags.md`](feature_flags.md).

### max_job_failures

**Type:** integer · **Default:** 3

Consecutive failure threshold. When a ScheduledTask accumulates this many consecutive failures it auto-pauses (state `auto_paused`). Also used as the retry budget ceiling for Job auto-close after repeated failures.

### main_concern_report_threshold

**Type:** integer · **Default:** 2 · **Min:** 1

Minimum number of repeated broken-main reports before the aggregator surfaces a main-branch concern.

## Landing queue

### merge_train_enabled

**Type:** boolean · **Default:** false

When true, approved Epic child Jobs do not land one-by-one. They wait until every open sibling is approved, then the Epic lands as a single atomic `merge_train` workflow. When false, approved Jobs land individually via `auto_merge`.

### merge_train_max_size

**Type:** integer · **Default:** 20

Maximum number of PRs that can participate in a single merge train. `merge_train_assemble` rejects the train if the member count exceeds this limit.

## Instance mode

### mode

**Type:** string · **Default:** `"advanced"` · **Values:** `"advanced"`, `"simple"`

Instance-wide experience mode. Set once during first-run onboarding (the "How do you work?" wizard step) or later in Admin → Settings → Instance mode.

- **`advanced`** — full developer experience: manual per-Job approvals, Coding Mode, Local Mode, scheduled tasks, GitHub Issues tab, and all operator controls are available.
- **`simple`** — non-technical solopreneur mode: developer-only surfaces are force-disabled regardless of their feature flag state. Specifically, `Feature.coding_mode_enabled?` and `Feature.local_mode_enabled?` always return `false`, and the feature-flag admin UI hides those rows. The main dashboard is job-centric: `App::DashboardPayload` forces `subject: "job"` (list view only), so every Job — any `kind` (`issue`/`cron`/`direct`) — is listed directly with its own status shown inline (`queued`/`running`/`implemented`/`approved`/`landing`/`closed`, plus the closure reason once closed) instead of behind an Epic rollup pill. Epics stay out of this primary view; Workflows, scheduled tasks, and the repository GitHub Issues tab are likewise not advertised in the UI. Pre-existing Epics from before this dashboard became job-centric are left alone architecturally — no data migration — but get a conditional nav entry ("Epics", linking to `/dashboard/epics`) that surfaces the unchanged epic-list rendering (`App::DashboardPayload#subject` honors an explicit `?subject=epic` override even in simple mode). The nav entry (`AppApi::BootstrapSerializer#legacy_epics_visible?`, exposed as `app.legacy_epics_visible` in the bootstrap payload) is visible only while the current user can still reach an Epic in a non-terminal state (`backlog`/`ready`/`in_progress`, i.e. not `done`/`archived`); it disappears once every reachable Epic has landed or been archived. Direct `/epics/:id` links keep working regardless of nav visibility, since no Epic data is deleted. Both the legacy epics list and the simple-mode `EpicDetail` page show a short banner explaining these are older, multi-step features created before the job-centric change, and that new requests now appear as individual tasks on the main dashboard. Child Jobs created under an Epic respect the repository's own `Repository#auto_merge_enabled` opt-in (`repository.auto_merge_enabled?`, default `false`) the same way advanced-mode Jobs do — simple mode does not force it on. Only when the repository has opted in do new child Jobs get `auto_merge_enabled: true` and the Epic get `auto_approve_mode: "if_graders_pass"`, so each child PR auto-approves and lands after repo-committed graders pass. When the repository has not opted in, simple-mode child Jobs stay `approved` (not auto-landed) until an operator or user approves them, same as advanced mode. Reviewing a standalone Job happens before it lands, not after: any Job (any `kind`, no `epic_id`) in `implemented`/`approved` state shows a one-click "Preview & Approve" action right on its dashboard row (`App::DashboardPayload#dashboard_job_json`'s `can_start_preview`/`can_approve` fields, computed only in simple mode). Preview reuses `App::PreviewAvailability.configured?` — the same registered-`:preview_provider`-plugin-or-`.syrus.yml`-`preview:`-block gate Job Detail's `PreviewPanel` uses — and the job-scoped preview start/stop endpoints; Approve calls the existing `POST /api/v1/app/jobs/:id/approve` endpoint (`job.approve!`, guarded by `job.may_approve?`). Legacy Epic child Jobs (`epic_id` present) are excluded from this per-Job action and keep reviewing through the Epic's post-merge rollup flow described next. Once all work Jobs close as merged, `Epic#review_ready?` surfaces the Epic as ready for feature-level review; the operator can approve the feature (`user_approved_at`) or submit feedback, which appends a new direct Job to the end of the Epic chain and returns the Epic to `in_progress`. Notifications are job-centric for standalone Jobs and feature-level for Epic children: `NotificationService::SIMPLE_JOB_CENTRIC_KINDS` (`job_failed`, `job_implemented`) still creates a per-Job notification in simple mode — with the Job and PR link intact — whenever the failing/implemented Job has no `epic_id`, so users see the failure on the Job that actually failed. Jobs that belong to a legacy Epic keep the old behavior: those two kinds stay suppressed and the Epic instead emits plain-language notifications when the feature is ready for review, when a terminal child failure needs operator attention, and when review feedback queues follow-up work. All other technical kinds (PR, branch, SHA, main-grader, grader-health, etc.) stay suppressed for every Job regardless of Epic membership. Implement, PR-feedback, and CI-repair agent prompts start with simple-mode guidance: ask one focused clarifying question only for genuinely ambiguous requests, use Syrus memory tools liberally, choose technical defaults without asking the operator, write tests, and complete the stated sub-task without TODO handoffs. Chat hides tool-call internals: running calls show only generic progress text, successful calls disappear, failed calls show "Hit a snag", and the chat workspace omits the Context tab.

Same-Epic `JobDependency` chain enforcement (no forks, no merges) is **not** mode-gated — `JobDependency` rejects fan-in/fan-out same-Epic edges on every create/update in both `advanced` and `simple` mode. See [Epic Dependency Policy](epic_dependency_policy.md).

Use `AppSetting.simple?` / `AppSetting.advanced?` in code to branch on mode. Changing mode takes effect immediately (no restart required) because `AppSetting.current` is called at request time. When changed from Admin → Settings, the UI confirms the mode-specific impact first; cancelling restores the previous selector value, and confirming saves the change then reloads the page so mode-gated navigation and copy refresh together.

### mode_configured_at

**Type:** datetime · **Default:** nil

Stamped automatically when an operator first explicitly sets the mode (via the onboarding wizard or Admin Settings). Nil on instances that have never had a mode explicitly set. Used by the onboarding checklist to track whether the mode step is complete.

## Instance operations

### signups_open

**Type:** boolean · **Default:** false

Allow new user registrations. Set to `false` on private instances.

### polling_paused

**Type:** boolean · **Default:** false

Emergency kill switch: pause all polling jobs (`PollAllRepositoriesJob`, `PollAllPullRequestsJob`, etc.). Jobs already running complete normally; no new issues or PR comments are picked up.

### runs_paused

**Type:** boolean · **Default:** false

Emergency kill switch: pause workflow execution. `RunJob` checks this flag and re-enqueues itself if true, so active Runs stay queued without losing state.

### report_issue_repo_slug

**Type:** string · **Default:** "tkadauke/syrus"

Controls where in-app bug reports are sent. The slug is also used for the "Report an issue" link displayed in the UI.

**Routing logic:** when a user submits a bug report, Syrus checks whether an active `Repository` record exists for this slug (system-wide match) or whether the user has a fork of it (`upstream_owner`/`upstream_name` match). If either is found, the report is filed as a direct Syrus Job against that repository. If neither is found, the report is filed as a plain GitHub issue via the API using the user's PAT; screenshots and attachments are uploaded to GitHub's asset CDN and embedded inline in the issue body.

On self-hosted instances, set this to the `owner/name` of your own Syrus fork. If the fork is tracked in Syrus as a repository, reports will be routed as Jobs; if not, they will be filed as GitHub issues against that slug.

### max_concurrent_agent_runs

**Type:** integer · **Default:** 0 (unlimited)

Global, cluster-wide cap on how many `:runs` queue Runs execute at once, across **all** worker pods. `RunJob` enforces it with a best-effort defer-and-re-enqueue gate (DB-counted, so it holds across pods). Set this when running multiple worker pods so total compute concurrency — and Claude/Codex cost and rate-limit exposure — does not scale with pod count; each pod's `JOB_CONCURRENCY` only bounds that single pod. `0` means no global cap. Main-branch grader Runs are on `:runs` and are counted; landing/merge Runs (`:merges` queue) are not counted, so they can't be starved by a saturated agent cap.

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

### github_app_registered_at

**Type:** datetime

When the GitHub App was registered. Informational; does not affect runtime behavior.

### github_app_installation_sync_started_at

**Type:** datetime

When the latest GitHub App installation sync attempt started. Used by the admin installation diagnostic and chat MCP diagnostic tool to distinguish a stale or never-run sync from a missing App installation.

### workflow_admission_policy

**Type:** string (`whole_workflow` or `phase_aware`)

Controls how `WorkflowAdmissionBudget` applies after a Workflow has started.
`whole_workflow` is the default: admission happens before start and the
Workflow keeps advancing through normal phase boundaries once admitted.
`phase_aware` keeps the tighter optimizer and may pause between phases when
predicted pressure is high. Hard worker memory/disk exhaustion can pause an
in-flight Workflow under either policy; paused Workflows keep their persisted
state but expose an apparent `paused` state in the dashboard.

### github_app_installation_sync_succeeded_at

**Type:** datetime

When the latest GitHub App installation sync completed successfully.

### github_app_installation_sync_duration_ms

**Type:** integer

Duration of the latest GitHub App installation sync attempt in milliseconds.

### github_app_installation_sync_records_seen

**Type:** integer

Number of installation records returned by GitHub during the latest successful sync attempt.

### github_app_installation_sync_error_class

**Type:** string

Ruby exception class from the latest failed installation sync attempt, cleared after a successful sync.

### github_app_installation_sync_error_message

**Type:** text

Exception message from the latest failed installation sync attempt, cleared after a successful sync.

## Video walkthroughs

### video_retention_days

**Type:** integer · **Default:** 7 · **Min:** 1

How long to retain walkthrough video blobs before `VideoWalkthroughPruneJob` deletes them. The analysis and screenshots persist indefinitely; only the raw video blob is pruned.

### video_storage_budget_mb

**Type:** integer · **Default:** 2048 (2 GB) · `0` = unlimited

Instance-wide storage budget for walkthrough video blobs, measured in megabytes. When the budget is exceeded, `VideoWalkthroughPruneJob` evicts the oldest blobs first (LRU). The class method `AppSetting.video_storage_budget_bytes` converts this to bytes for internal use.

## External platform integrations

### telegram_bot_handle

**Type:** string · **Default:** nil

The `@handle` of the Syrus Telegram bot (e.g. `syrus_bot`). Setting this marks Telegram as configured; `AppSetting.telegram_configured?` returns true and the Connected Platforms UI shows Telegram as available. The Telegram integration itself (long-poll adapter) is a separate job that registers via `PlatformPollingJob.registry`; this setting is what that job checks in its `configured?` guard.

### discord_bot_token

**Type:** string (encrypted) · **Default:** nil

The bot token used by the `discord` plugin's Gateway connector (`Discord::GatewayConnectionJob`) and outbound adapter (`Discord::PlatformAdapter`). `AppSetting.discord_bot_token` is the gate `Discord::GatewayConnectionJob#configured?` checks before opening a Gateway connection; it is separate from the `discord` `PluginRecord`'s install/enable toggle -- the plugin can be enabled with no token set (no connector starts) or disabled with a token already configured.

## Coding-Mode workspaces

### chat_coding_workspace_budget_mb

**Type:** integer · **Default:** 0 (unlimited) · `0` = disabled

Instance-wide byte budget for retained Coding-Mode chat checkouts (each is a writable full clone plus installed dependencies, commonly 1–2 GB), measured in megabytes. When retained checkouts exceed the budget, `WorkflowWorkspacePruneJob` calls `ChatWorkspace.reclaim_coding_over_budget!` to LRU-evict the least-recently-active ones until total on-disk size is under budget — after safely backing up any un-pushed / uncommitted work to the remote (see the Coding Mode docs). `0` disables the size cap; the idle-reclaim window (`ChatWorkspace::RECLAIM_IDLE_CODING_AFTER`, 48 h) and reclaim-on-handoff still apply. Set this on busy instances where coding chats would otherwise fill the worker's data volume. `AppSetting.chat_coding_workspace_budget_bytes` converts it to bytes.
