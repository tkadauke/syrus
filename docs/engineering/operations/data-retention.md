# Data retention


Per-table DB row retention windows are declared in `RetentionPolicyRegistry`
and persisted by stable policy key in `retention_policy_settings`. Effective
durations are stored as canonical seconds; `NULL` means explicit infinite
retention. The admin API and UI continue to present the registry's display
unit and preserve the `0` = infinite convention: a `0` value makes the shared
policy worker a no-op. Models include the shared
`HasConfigurableRetention` concern and declare `configurable_retention
setting_key:, unit:` once; the concern exposes `retention_window` (nil when
infinite), `retention_cutoff` (a `Time`, nil when infinite), and
`retention_floor(now:)` (a `Time`, the epoch when infinite — used to clamp
"since"/"floor" query defaults rather than assuming data exists arbitrarily
far back) as class methods.

`RetentionPolicyRegistry.definitions` recomputes on every call, merging
`CORE_DEFINITIONS` with whatever any installed plugin contributes via the
`:retention_policy` extension point (`Syrus::Plugin::RetentionPolicy`). Only
enabled providers participate in active discovery. A disabled or removed
plugin may leave an inert `retention_policy_settings` row, preserving its
operator choice without loading plugin classes. A plugin that owns a prunable
table (e.g. `metrics_dashboard`) must never be hand-listed in core's
`CORE_DEFINITIONS` — a core file naming a plugin's model or executor class by string
would make that plugin undeletable in practice (see CLAUDE.md's "core specs
must not enumerate plugin-provided things" rule). See
`plugins/metrics_dashboard/app/services/metrics_dashboard/retention_policy.rb`
for the reference implementation.

Scope is limited to DB-table row retention (MySQL/SQLite). Disk/blob-based
retention (`WorkflowWorkspacePruneJob`'s workspace-directory constants,
`ChatWorkspace::RECLAIM_IDLE_CODING_AFTER`, `CoverageHitMapTtlPruneJob::TTL_DAYS`,
and the video walkthrough settings documented above) is out of scope and
stays fixed or on its own settings.

`RetentionSweepJob` runs every ten minutes and enqueues one `RetentionPolicyPruneJob` per
active stable key. A plugin provider that fails while declaring its policies is logged
and skipped, so it cannot prevent core or other plugin policies from being scheduled.
The worker resolves the current setting, deletes at most 50
ordered 1,000-row batches, and re-enqueues only that key after one minute when
eligible rows remain. `SkipIfPending` plus a Solid Queue concurrency key
deduplicates each policy without coupling failures between policies. A normal
core or plugin policy needs only a registry definition—no ApplicationJob or
recurring YAML entry. Definitions may name a small executor strategy when
dependent-row cleanup or another side effect is required.

| Setting | Default | Unit | Table | Executor | Archivable |
| --- | --- | --- | --- | --- | --- |
| `job_log_retention_days` | 30 | days | `job_logs` | generic | yes |
| `draft_visual_evidence_retention_days` | 7 | days | `workflow_visual_evidences` | attachment cleanup strategy | no |
| `performance_log_event_retention_hours` | 24 | **hours** | `performance_log_events` | generic | no |
| `run_diagnostic_retention_days` | 30 | days | `run_diagnostics` | generic | yes |
| `run_resource_summary_retention_days` | 30 | days | `run_resource_summaries` | generic | no |
| `worker_host_health_sample_retention_days` | 7 | days | `worker_host_health_samples` | generic | no |
| `work_engine_reconciler_activity_retention_days` | 7 | days | `work_engine_reconciler_activity_events` | generic | yes |
| `provider_session_retention_days` | 14 | days | `provider_sessions` | payload cleanup strategy | yes |
| `spawned_process_retention_days` | 7 | days | `spawned_processes` | dependent-row strategy | no |
| `notification_retention_days` | 30 | days | `notifications` | generic | no |
| `operational_log_event_retention_hours` | 6 | **hours** | `operational_log_events` | index cleanup strategy | no |
| `metrics_dashboard_sample_retention_days` | 7 | days | `metrics_dashboard_samples` | generic | no |
| `test_insight_case_retention_days` | 90 | days | `test_insight_cases` | plugin strategy | no |
| `run_health_snapshot_retention_days` | 7 | days | `run_health_snapshots` | generic | yes |
| `main_branch_health_check_retention_days` | 7 | days | `main_branch_health_checks` | generic | yes |
| `workflow_step_resource_profile_retention_days` | 180 | days | `workflow_step_resource_profiles` | generic | no |

"Archivable" means the entry's `RetentionPolicyRegistry::Definition#archivable`
flag is `true` — see "Archive-before-delete storage" below for what that
enables. It is reserved for tables with real forensic/audit value after
deletion (exception diagnostics, agent session transcripts, automated-repair
and CI-health audit trails); high-volume numeric telemetry and ops-noise
tables (resource summaries, host health samples, spawned-process inventory,
notifications, the operational log index, and the resource-prediction
profile tables) are marked `archivable: false` since archiving them would
mostly balloon storage for little later value.

`job_log_retention_days` controls the detailed output shown for a Run. After
the default 30-day window, stdout, stderr, tool-call, and system chunks are
deleted while the Run and its other history remain. Enable
`job_log_archive_before_delete` before pruning if that detailed output must be
preserved outside the live table. `performance_log_event_retention_hours` is a
short diagnostic window; its default remains the 24 hours used by the
performance UI.

`draft_visual_evidence_retention_days` controls unsubmitted screenshots captured
during visual-review Runs. The default seven-day window gives operators time to
recover an omitted capture without retaining every draft indefinitely. Submitted
evidence is excluded from this policy and remains attached to its Workflow.

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

Three entries are worth calling out:

- **`operational_log_event_retention_hours`** is Syrus's own operational log
  index — a high-volume, short-lived table — so its unit is hours, not days.
  `OperationalLogEvent.retention_floor(now:)` clamps "since"/"floor" query
  defaults across `OperationalLogIndex`, `OperationalLogSearch`, and
  `Admin::OperationalLogsPayload` to the configured window (or the epoch, when
  infinite) instead of assuming data always exists back to a fixed constant.
- **`workflow_step_resource_profile_input_retention_days`** does not back a
  deletion scope or retention policy. It bounds how far back
  `WorkflowStepResourceProfiles::Refresh` looks at `RunResourceSummary` rows
  when rebuilding prediction profiles — a lookback window, not a retention
  window — via `WorkflowStepResourceProfile.input_retention_window`. The
  profile *rows* themselves are governed by the sibling
  `workflow_step_resource_profile_retention_days` setting and the `.stale`
  scope (also pruned inline by `WorkflowStepResourceProfileRefreshJob`).
- **`metrics_dashboard_sample_retention_days`** is the one plugin-owned
  entry in the table above. It is contributed by the `metrics_dashboard`
  plugin via the `:retention_policy` extension point rather than hand-listed
  in `RetentionPolicyRegistry::CORE_DEFINITIONS`, so the plugin stays
  physically removable (`bin/plugin-boundary-audit metrics_dashboard`). The
  persisted row may remain while the plugin is disabled, but active discovery,
  and its `.prunable` scope go inert. Its seven-day default matches the
  dashboard's longest selectable window; the shared sweep enforces it.

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
the entry's current `RetentionPolicySetting` value. Each row shows the table's current
row count/byte size, its projected max size at the configured retention (or
"Unbounded" when the setting is `0`), and, when available-space data exists,
that max size as a percentage of available space; when available space is
`unknown` the page surfaces the `retention_available_space_override_gb`
input inline instead of a blank comparison. Each row edits its own retention
window independently (a required numeric input plus an "infinite retention"
toggle) rather than one flat form, since the settings are unrelated to each
other. `PATCH /api/v1/app/admin/retention_settings` accepts `0` as the
infinite sentinel only when the matching `<setting_key>_infinite` flag is
also true; blank finite inputs and bare zeroes are rejected before updating
the dedicated policy store, so clearing a field while retyping cannot silently
disable age-based pruning. Nonzero values must be positive integers. This page
covers only the DB-table entries in the registry; the
existing walkthrough-video retention/budget settings documented above stay on
`/settings/edit`.

### Archive-before-delete storage (`RetentionArchive`)

An opt-in path where the policy worker serializes and archives a pruned
batch to Active Storage before deleting it, instead of hard-deleting it
outright. `RetentionArchive` (`app/models/retention_archive.rb`,
`retention_archives` table) records one archived batch: `retention_key`
(must match a `RetentionPolicyRegistry` key), `pruned_before` (the cutoff
used for that prune run), `row_count`, `byte_size`, and a `has_one_attached
:archive_file` holding the serialized batch. v1 is download-only: archived
blobs are kept forever and there is no automated restore path back into the
live table.

**Opt-in flag.** `RetentionPolicyRegistry::Definition#archivable` marks which
entries archiving is meaningful for (see the table above). Every archivable
entry stores its archive choice on the same `RetentionPolicySetting` row.
Every one defaults to `false` — archiving is off until an operator explicitly
enables it — while non-archivable policies always store `NULL` for that field.

**`RetentionPruner`** (`app/services/retention_pruner.rb`) is the shared
bounded-delete service used by retention executors. It selects ordered
primary-key batches (1,000 rows by default), processes at most 50 batches per
run, and commits each batch separately. MySQL workers claim rows with
`FOR UPDATE SKIP LOCKED`, allowing overlapping workers to process distinct
batches without duplicate archives; SQLite development/test processes
serialize batch selection in-process. Archivable policies supply a retention key
and cutoff:

```ruby
RetentionPruner.call(
  scope: RunDiagnostic.prunable,
  retention_key: :run_diagnostic,
  cutoff: RunDiagnostic.retention_cutoff
)
```

For each selected batch, `RetentionPruner` passes an exact primary-key scope
to `RetentionArchiver` and deletes exactly those IDs in the same transaction.
Concurrent inserts cannot join a delete after its archive is created, and a
row selected for the batch cannot be omitted from that archive if its cutoff
column changes. `RetentionArchiver.call` no-ops (never touches `RetentionArchive` or Active
Storage) when the table's `archive_before_delete` setting is off, the cutoff
is `nil` (infinite retention), or the batch has no rows — so the
flag-off path remains delete-only. When
archiving is on and there is something to archive, it serializes each row of
`scope` via `#as_json` to gzip-compressed JSONL, streaming through
`find_in_batches` (default batch size 1000) so the whole prunable set is
never loaded into memory at once, then creates exactly one `RetentionArchive`
row for the prune batch (`row_count`, `byte_size`, `pruned_before: cutoff`) with
the compressed file attached. Passing a `retention_key` whose definition has
`archivable: false` raises `ArgumentError`.

Archiving tables as of this writing: `run_diagnostic`,
`work_engine_reconciler_activity`, `provider_session`, `run_health_snapshot`,
and `main_branch_health_check`; the generic executor supplies their keys to
the shared archive/delete transaction path.

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
