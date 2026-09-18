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

The `@handle` of the Syrus Telegram bot (e.g. `syrus_bot`). Setting this marks Telegram as configured; `AppSetting.telegram_configured?` returns true and the Connected Platforms UI shows Telegram as available. The Telegram integration itself (long-poll adapter) is a separate job that registers via `PlatformPollingJob.registry`; this setting is what that job checks in its `configured?` guard.

### discord_bot_token

**Type:** string (encrypted) · **Default:** nil

The bot token used by the `discord` plugin's Gateway connector (`Discord::GatewayConnectionJob`) and outbound adapter (`Discord::PlatformAdapter`). `AppSetting.discord_bot_token` is the gate `Discord::GatewayConnectionJob#configured?` checks before opening a Gateway connection; it is separate from the `discord` `PluginRecord`'s install/enable toggle -- the plugin can be enabled with no token set (no connector starts) or disabled with a token already configured.

## Coding-Mode workspaces

### chat_coding_workspace_budget_mb

**Type:** integer · **Default:** 0 (unlimited) · `0` = disabled

Instance-wide byte budget for retained Coding-Mode chat checkouts (each is a writable full clone plus installed dependencies, commonly 1–2 GB), measured in megabytes. When retained checkouts exceed the budget, `WorkflowWorkspacePruneJob` calls `ChatWorkspace.reclaim_coding_over_budget!` to LRU-evict the least-recently-active ones until total on-disk size is under budget — after safely backing up any un-pushed / uncommitted work to the remote (see the Coding Mode docs). `0` disables the size cap; the idle-reclaim window (`ChatWorkspace::RECLAIM_IDLE_CODING_AFTER`, 48 h) and reclaim-on-handoff still apply. Set this on busy instances where coding chats would otherwise fill the worker's data volume. `AppSetting.chat_coding_workspace_budget_bytes` converts it to bytes.

## Data retention

Per-table DB row retention windows are declared in `RetentionPolicyRegistry`
(`app/models/retention_policy_registry.rb`), not hand-listed here or in
`AppSettingRegistry` — `AppSettingRegistry.definitions` folds each entry in
as an admin-editable integer setting (`RetentionPolicyRegistry::Definition#as_app_setting_definition`),
so validations and admin metadata stay in sync automatically. Every setting
follows the same `0` = infinite retention convention as
`video_storage_budget_mb`: a `0` value means the corresponding scope returns
`.none` and the PruneJob is a no-op. Models include the shared
`HasConfigurableRetention` concern and declare `configurable_retention
setting_key:, unit:` once; the concern exposes `retention_window` (nil when
infinite), `retention_cutoff` (a `Time`, nil when infinite), and
`retention_floor(now:)` (a `Time`, the epoch when infinite — used to clamp
"since"/"floor" query defaults rather than assuming data exists arbitrarily
far back) as class methods.

`RetentionPolicyRegistry.definitions` recomputes on every call, merging
`CORE_DEFINITIONS` with whatever any installed plugin contributes via the
`:retention_policy` extension point (`Syrus::Plugin::RetentionPolicy`,
`Syrus::PluginRegistry.all_plugins` — unfiltered by enabled state, since the
AppSetting column and its validation/admin metadata must exist regardless of
whether the plugin happens to be enabled). A plugin that owns a prunable
table (e.g. `metrics_dashboard`) must never be hand-listed in core's
`CORE_DEFINITIONS` — a core file naming a plugin's model/job class by string
would make that plugin undeletable in practice (see CLAUDE.md's "core specs
must not enumerate plugin-provided things" rule). See
`plugins/metrics_dashboard/app/services/metrics_dashboard/retention_policy.rb`
for the reference implementation.

Scope is limited to DB-table row retention (MySQL/SQLite). Disk/blob-based
retention (`WorkflowWorkspacePruneJob`'s workspace-directory constants,
`ChatWorkspace::RECLAIM_IDLE_CODING_AFTER`, `CoverageHitMapTtlPruneJob::TTL_DAYS`,
and the video walkthrough settings documented above) is out of scope and
stays fixed or on its own settings.

| Setting | Default | Unit | Table | PruneJob | Archivable |
| --- | --- | --- | --- | --- | --- |
| `run_diagnostic_retention_days` | 30 | days | `run_diagnostics` | `RunDiagnosticPruneJob` | yes |
| `run_resource_summary_retention_days` | 30 | days | `run_resource_summaries` | `RunResourceSummaryPruneJob` | no |
| `worker_host_health_sample_retention_days` | 7 | days | `worker_host_health_samples` | `WorkerHostHealthSamplePruneJob` | no |
| `work_engine_reconciler_activity_retention_days` | 7 | days | `work_engine_reconciler_activity_events` | `WorkEngineReconcilerActivityPruneJob` | yes |
| `provider_session_retention_days` | 14 | days | `provider_sessions` | `ProviderSessionPruneJob` | yes |
| `spawned_process_retention_days` | 7 | days | `spawned_processes` | `SpawnedProcessPruneJob` | no |
| `notification_retention_days` | 30 | days | `notifications` | `PruneOldNotificationsJob` | no |
| `operational_log_event_retention_hours` | 6 | **hours** | `operational_log_events` | `PruneOperationalLogsJob` | no |
| `metrics_dashboard_sample_retention_days` | 30 | days | `metrics_dashboard_samples` | `MetricsDashboard::PruneJob` | no |
| `run_health_snapshot_retention_days` | 7 | days | `run_health_snapshots` | `RunHealthSnapshotPruneJob` | yes |
| `main_branch_health_check_retention_days` | 7 | days | `main_branch_health_checks` | `MainBranchHealthCheckPruneJob` | yes |
| `workflow_step_resource_profile_retention_days` | 180 | days | `workflow_step_resource_profiles` | `WorkflowStepResourceProfilePruneJob` | no |
| `workflow_step_resource_profile_input_retention_days` | 180 | days | (lookback only — see below) | none | no |

"Archivable" means the entry's `RetentionPolicyRegistry::Definition#archivable`
flag is `true` — see "Archive-before-delete storage" below for what that
enables. It is reserved for tables with real forensic/audit value after
deletion (exception diagnostics, agent session transcripts, automated-repair
and CI-health audit trails); high-volume numeric telemetry and ops-noise
tables (resource summaries, host health samples, spawned-process inventory,
notifications, the operational log index, and the resource-prediction
profile tables) are marked `archivable: false` since archiving them would
mostly balloon storage for little later value.

Three entries are worth calling out:

- **`operational_log_event_retention_hours`** is Syrus's own operational log
  index — a high-volume, short-lived table — so its unit is hours, not days.
  `OperationalLogEvent.retention_floor(now:)` clamps "since"/"floor" query
  defaults across `OperationalLogIndex`, `OperationalLogSearch`, and
  `Admin::OperationalLogsPayload` to the configured window (or the epoch, when
  infinite) instead of assuming data always exists back to a fixed constant.
- **`workflow_step_resource_profile_input_retention_days`** does not back a
  deletion scope or PruneJob. It bounds how far back
  `WorkflowStepResourceProfiles::Refresh` looks at `RunResourceSummary` rows
  when rebuilding prediction profiles — a lookback window, not a retention
  window — via `WorkflowStepResourceProfile.input_retention_window`. The
  profile *rows* themselves are governed by the sibling
  `workflow_step_resource_profile_retention_days` setting and the `.stale`
  scope (already pruned inline by `WorkflowStepResourceProfileRefreshJob`;
  `WorkflowStepResourceProfilePruneJob` is an independently schedulable
  safety net on top of that).
- **`metrics_dashboard_sample_retention_days`** is the one plugin-owned
  entry in the table above. It is contributed by the `metrics_dashboard`
  plugin via the `:retention_policy` extension point rather than hand-listed
  in `RetentionPolicyRegistry::CORE_DEFINITIONS`, so the plugin stays
  physically removable (`bin/plugin-boundary-audit metrics_dashboard`). The
  column itself is still added by a core migration and validated/exposed in
  admin settings unconditionally, the same as other plugin-owned settings
  like `discord_bot_token` — only the model's `.prunable` scope and PruneJob
  go inert while the plugin is disabled.

### Retention size estimation

`TableSizeEstimator` (`app/services/table_size_estimator.rb`) returns a fast,
approximate `{ row_count_estimate, byte_size_estimate }` for a table name —
never `COUNT(*)` or a full scan. It branches on
`ActiveRecord::Base.connection.adapter_name` (the same idiom as
`PluginRecord.search`): MySQL reads `information_schema.TABLES`
(`TABLE_ROWS`, `DATA_LENGTH + INDEX_LENGTH`), which are InnoDB engine
estimates that can drift between `ANALYZE TABLE` runs; SQLite feature-detects
the `dbstat` virtual table (some builds lack `SQLITE_ENABLE_DBSTAT_VTAB`) for
byte size and falls back to `nil` when it's unavailable, and uses
`MAX(rowid)` as a fast row-count proxy, which undercounts after heavy
deletes — an accepted tradeoff for an estimate.

`RetentionSizeSnapshotJob` (`queue: cleanup`, hourly via `config/recurring.yml`)
iterates every `RetentionPolicyRegistry` entry (core and plugin-contributed
alike — never a hand-listed table set), estimates its table, reads the
entry's current `AppSetting` retention value, and caches one
`RetentionSizeSnapshotJob::TableSnapshot` per entry via `Rails.cache`
(mirroring `DataRootDiskUsage`'s cached-snapshot/TTL pattern). It also
computes `bytes_per_unit_estimate` (`current_byte_size / current_retention_value`)
and `estimated_max_byte_size` (`bytes_per_unit_estimate * configured_retention_value`)
so a future admin page doesn't need to recompute them; both are `nil` when
the table is currently empty or the configured retention is already infinite
(`0`) — there's no rate or ceiling to project in either case. The admin page
must read `RetentionSizeSnapshotJob.table_snapshot(key)` /
`.available_space` from cache, never compute these synchronously on page
load.

The job also caches one shared `AvailableSpace` snapshot
(`{ available_bytes, source, computed_at }`). `source` is one of:

- **`manual`** — the `retention_available_space_override_gb` `AppSetting`
  (below) is set and takes priority over automatic inference.
- **`measured`** — automatic inference succeeded: `DataRootDiskUsage.refresh!`
  in SQLite local mode (`SYRUS_SQLITE`), or a `df`-based read of MySQL's
  `@@datadir` filesystem when that path is locally readable.
- **`unknown`** — neither a manual override nor automatic inference is
  available (the common case for managed/remote MySQL, where `@@datadir`
  isn't a path this process can see).

### retention_available_space_override_gb

**Type:** integer · **Default:** 0 (unset) · **Min:** 0

Manual fallback for the retention page's "available space" figure, in
gigabytes, used when `RetentionSizeSnapshotJob`'s automatic inference can't
determine it. `AppSetting.retention_available_space_override_bytes` returns
`nil` when unset (`0`) so the job can distinguish "no override" from "an
operator picked 0 GB."

### Admin Retention Settings page

`/admin/retention_settings` (React: `RetentionSettings.tsx`; API:
`Api::V1::App::Admin::RetentionSettingsController`, `GET`/`PATCH
/api/v1/app/admin/retention_settings`) renders one row per
`RetentionPolicyRegistry` entry — never a hand-listed table set in the
controller — joining in the cached `RetentionSizeSnapshotJob` sizing data and
the entry's current `AppSetting` value. Each row shows the table's current
row count/byte size, its projected max size at the configured retention (or
"Unbounded" when the setting is `0`), and, when available-space data exists,
that max size as a percentage of available space; when available space is
`unknown` the page surfaces the `retention_available_space_override_gb`
input inline instead of a blank comparison. Each row edits its own retention
window independently (a numeric input plus an "infinite retention" toggle
that zeroes the value) rather than one flat form, since the settings are
unrelated to each other. `update` validates against the same
`AppSettingRegistry`-derived numericality bounds as every other retention
setting, so `0` is always accepted as the infinite sentinel. This page covers
only the DB-table entries in the registry; the existing walkthrough-video
retention/budget settings documented above stay on `/settings/edit`.

### Archive-before-delete storage (`RetentionArchive`)

An opt-in path where a table's PruneJob serializes and archives a pruned
batch to Active Storage before deleting it, instead of hard-deleting it
outright. `RetentionArchive` (`app/models/retention_archive.rb`,
`retention_archives` table) records one archived sweep: `retention_key`
(must match a `RetentionPolicyRegistry` key), `pruned_before` (the cutoff
used for that sweep), `row_count`, `byte_size`, and a `has_one_attached
:archive_file` holding the serialized batch. v1 is download-only: archived
blobs are kept forever and there is no automated restore path back into the
live table.

**Opt-in flag.** `RetentionPolicyRegistry::Definition#archivable` marks which
entries archiving is meaningful for (see the table above). Every archivable
entry gets a matching `<key>_archive_before_delete` boolean `AppSetting`
column (`Definition#archive_setting_key`), folded into
`AppSettingRegistry.definitions` via
`RetentionPolicyRegistry.archive_app_setting_definitions` the same way
`as_app_setting_definition` folds the retention-window integer settings in.
Every one of these defaults to `false` — archiving is off for every table
until an operator explicitly enables it — and a non-archivable entry has no
such column at all.

**`RetentionArchiver`** (`app/services/retention_archiver.rb`) is the shared
service each archivable table's PruneJob calls immediately before its
existing delete:

```ruby
scope = RunDiagnostic.prunable
RetentionArchiver.call(retention_key: :run_diagnostic, scope: scope, cutoff: RunDiagnostic.retention_cutoff)
n = scope.delete_all
```

`RetentionArchiver.call` no-ops (never touches `RetentionArchive` or Active
Storage) when the table's `archive_before_delete` setting is off, the cutoff
is `nil` (infinite retention), or the scope has no rows this sweep — so the
flag-off path is byte-for-byte the original delete-only behavior. When
archiving is on and there is something to archive, it serializes each row of
`scope` via `#as_json` to gzip-compressed JSONL, streaming through
`find_in_batches` (default batch size 1000) so the whole prunable set is
never loaded into memory at once, then creates exactly one `RetentionArchive`
row for the sweep (`row_count`, `byte_size`, `pruned_before: cutoff`) with the
compressed file attached. The caller's `scope.delete_all` then runs
unconditionally, whether or not archiving ran — the same `scope` object is
reused for both, so the delete never picks up rows that weren't included in
that archive. Passing a `retention_key` whose definition has
`archivable: false` raises `ArgumentError`.

Archiving tables as of this writing: `run_diagnostic`,
`work_engine_reconciler_activity`, `provider_session`, `run_health_snapshot`,
and `main_branch_health_check` — see their respective PruneJobs
(`RunDiagnosticPruneJob`, `WorkEngineReconcilerActivityPruneJob`,
`ProviderSessionPruneJob`, `RunHealthSnapshotPruneJob`,
`MainBranchHealthCheckPruneJob`) for the exact call sites.

**Admin UI.** `/admin/retention_settings` (`app/frontend/routes/RetentionSettings.tsx`)
exposes an "Archive before delete" checkbox next to each archivable table's
retention window, saved via the same `PATCH /api/v1/app/admin/retention_settings`
endpoint as the retention window itself
(`Api::V1::App::Admin::RetentionSettingsController#update_params` permits
every `archive_setting_key` alongside the window `setting_key`s; unlike the
integer settings, a `false` toggle must not be dropped as "blank", so this
filter rejects only `nil`/`""`, not every Ruby-falsy value). Each archivable
row also has a "View archives" toggle that expands a per-table history of
past `RetentionArchive` sweeps (`pruned_before`, row count, size, archived-at,
and a download link) via `GET /api/v1/app/admin/retention_archives?retention_key=<key>`
(`Api::V1::App::Admin::RetentionArchivesController`, paginated 20/page). The
download link (`GET .../retention_archives/:id/download`) is a plain
admin-auth-gated redirect to Active Storage's own signed blob URL
(`rails_blob_path(archive.archive_file, disposition: "attachment")`) rather
than streaming the file through the Rails process itself. v1 is
download-only — there is no restore action in this UI, matching
`RetentionArchive`'s download-only v1 scope above.

`archive_file` is deliberately **not** stored on the app's primary
`config.active_storage.service` — an operator archiving to keep MySQL/SQLite
lean usually wants that data on cheap bulk storage (a dedicated large local
disk, or a separate bucket), independent of wherever regular attachments
(user uploads, coverage hit maps, etc.) live. Resolution:

- `config/storage.yml` defines `retention_archive_disk` (Disk-backed, root
  from `RETENTION_ARCHIVE_ROOT`, defaulting to `storage/retention_archives`
  under the app root) and `retention_archive_s3` (S3-compatible, configured
  via `RETENTION_ARCHIVE_S3_*` env vars, mirroring the primary `minio` block
  but independently so archives can live in a different bucket/endpoint).
- `Rails.application.config.retention_archive_storage_service` picks which
  configured service is active, set per environment file via
  `RetentionArchiveStorageConfig.resolve(config)` (`config/retention_archive_storage.rb`).
  `RETENTION_ARCHIVE_STORAGE_SERVICE` overrides; unset falls back to the
  primary `config.active_storage.service`, so a zero-config deployment
  archives to the same place as its regular attachments until an operator
  explicitly points archives elsewhere.
- The model passes that resolved service to `has_one_attached
  :archive_file, service: ...` (Active Storage's per-attachment `service:`
  option), so `archive_file` blobs always land on the configured
  retention-archive service even when it differs from the primary one.
