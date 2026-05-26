# Plan: site-wide magic constants → AppSetting

_Part of the [magic-constants index](magic-constants-INDEX.md)._

## Context

`AppSetting` already holds four site-wide knobs (`signups_open`,
`max_job_failures`, `polling_paused`, `runs_paused`). This plan
migrates a much larger cohort of compiled-in constants over to it.
Most are operational policy: how stale is "stale," how long do we
retain artifacts, how aggressive are agent budgets. Today changing
any of them requires a deploy. After this plan, an admin can tune
them from `/settings/edit`.

The migrations break into themes:

- **Health / staleness thresholds** — what counts as "stuck"
- **Retention windows** — how long do we keep terminal Run artifacts
- **Agent budgets** — wall-clock + turns + diff size for agent calls
- **Cron floors** — minimum intervals on user-defined schedules
- **Operator UI thresholds** — what colors badges yellow vs red

## Constants to migrate

### Health / staleness thresholds

| Constant | Current | Notes |
|---|---|---|
| `Run::STALE_HEARTBEAT_THRESHOLD` | `30.minutes` | The reaper's cap. If we made it smaller, sluggish-but-alive Runs (e.g. an agent thinking hard) get nuked. If larger, deploy-killed runs stay "running" in the UI longer. |
| `Admin::StuckItems::ADMIN_STUCK_THRESHOLD` | `5.minutes` | Earlier signal — used in `/admin/overview` to flag concerning-but-not-yet-dead runs. Should always be < `STALE_HEARTBEAT_THRESHOLD`. |
| `DiagnoseRunJob::WARNING_HEARTBEAT` | `5.minutes` | Yellow threshold for the per-Run diagnose card. |

Schema:

```sql
ALTER TABLE app_settings
  ADD COLUMN run_stale_heartbeat_seconds INTEGER NOT NULL DEFAULT 1800,  -- 30 min
  ADD COLUMN admin_stuck_warning_seconds INTEGER NOT NULL DEFAULT 300,   -- 5 min
  ADD COLUMN diagnose_warning_seconds    INTEGER NOT NULL DEFAULT 300;   -- 5 min
```

Validation: warning < stale (a stuck-warning > stale-cap makes the
admin UI's "warning" tier disappear).

### Retention windows

| Constant | Current |
|---|---|
| `WorkflowWorkspacePruneJob::RETAIN_AFTER_SUCCESS_OR_CANCEL` | `2.hours` |
| `WorkflowWorkspacePruneJob::RETAIN_AFTER_FAILURE` | `7.days` |
| Provider transcript retention | `14.days` |
| `RunDiagnostic::RETAIN_AFTER` | `30.days` |
| `RunHealthSnapshot::RETAIN_AFTER` | `7.days` |
| `Invitation::DEFAULT_TTL` | `7.days` |

These are direct disk/DB pressure controls. The household's deploy
might want shorter retention on small clusters, longer for forensic
work. After issue #118 (workflow-dir cleanup leak) is fixed, the
`workflow_workspace_*` retention values become the operator's lever
to balance disk usage vs ability to inspect failed runs.

```sql
ALTER TABLE app_settings
  ADD COLUMN workflow_retain_after_success_seconds INTEGER NOT NULL DEFAULT 7200,    -- 2h
  ADD COLUMN workflow_retain_after_failure_seconds INTEGER NOT NULL DEFAULT 604800,  -- 7d
  ADD COLUMN claude_session_retain_seconds         INTEGER NOT NULL DEFAULT 1209600, -- 14d
  ADD COLUMN run_diagnostic_retain_seconds         INTEGER NOT NULL DEFAULT 2592000, -- 30d
  ADD COLUMN run_health_snapshot_retain_seconds    INTEGER NOT NULL DEFAULT 604800,  -- 7d
  ADD COLUMN invitation_default_ttl_seconds        INTEGER NOT NULL DEFAULT 604800;  -- 7d
```

### Agent budgets

| Constant | Current |
|---|---|
| `AgentInvocation::DEFAULT_TIMEOUT_SECONDS` | `30.minutes` (`1800`) |
| `AgentInvocation::DEFAULT_MAX_TURNS` | `200` |
| `PrSummarizer::DEFAULT_TIMEOUT_SECONDS` | `2.minutes` (`120`) |
| `PullRequestSummary::MAX_DIFF_BYTES` | `30_000` |
| `Steps::Prepare::PER_COMMAND_TIMEOUT` | `10.minutes` (`600`) |
| `Steps::Summarize::SUMMARIZE_TURN_BUDGET` | `5` |
| `Steps::SummarizeAmend::SUMMARIZE_TURN_BUDGET` | `5` |

`AgentInvocation::DEFAULT_MAX_TURNS` is already overridden per-user
via `User#agent_max_turns`. Same pattern applies to the others —
`AppSetting` provides the system default; per-repo overrides come in
the [per-repository plan](magic-constants-per-repository.md).

```sql
ALTER TABLE app_settings
  ADD COLUMN agent_default_timeout_seconds       INTEGER NOT NULL DEFAULT 1800,
  ADD COLUMN agent_default_max_turns             INTEGER NOT NULL DEFAULT 200,
  ADD COLUMN pr_summarizer_timeout_seconds       INTEGER NOT NULL DEFAULT 120,
  ADD COLUMN pr_summarizer_max_diff_bytes        INTEGER NOT NULL DEFAULT 30000,
  ADD COLUMN prepare_per_command_timeout_seconds INTEGER NOT NULL DEFAULT 600,
  ADD COLUMN summarize_step_turn_budget          INTEGER NOT NULL DEFAULT 5;
```

### Cron floors + miscellaneous tuning

| Constant | Current |
|---|---|
| `CronTemplate::MIN_CRON_INTERVAL` / `ScheduledTask::MIN_CRON_INTERVAL` | `1.hour` |
| `StepDispatcher::MERGEABILITY_RECHECK_DELAY` | `30.seconds` |
| `RunJob::RUNS_PAUSED_RETRY_DELAY` | `30.seconds` |

```sql
ALTER TABLE app_settings
  ADD COLUMN cron_min_interval_seconds         INTEGER NOT NULL DEFAULT 3600,
  ADD COLUMN mergeability_recheck_delay_seconds INTEGER NOT NULL DEFAULT 30,
  ADD COLUMN runs_paused_retry_delay_seconds   INTEGER NOT NULL DEFAULT 30;
```

## Code shape

A representative migration step (do this once per constant):

```ruby
# Before
class Run < ApplicationRecord
  STALE_HEARTBEAT_THRESHOLD = 30.minutes
end

# After
class Run < ApplicationRecord
  def self.stale_heartbeat_threshold
    AppSetting.current.run_stale_heartbeat_seconds.seconds
  end
  # Backwards-compat shim; remove in a follow-up sweep once callers
  # have migrated.
  STALE_HEARTBEAT_THRESHOLD = stale_heartbeat_threshold
end
```

Most constants only have a couple of call sites, so the migration is
small per-constant. Use a class method (not a constant pointing at a
method's return) so changing the AppSetting takes effect without a
restart — `Run::STALE_HEARTBEAT_THRESHOLD` would otherwise be frozen
at boot.

A cleaner final shape (after caller migration) is no constant at all,
just `AppSetting.current.run_stale_heartbeat_seconds.seconds`.

## Admin UI

Extend `app/views/settings/edit.html.erb` (the existing AppSetting
form) with an organized section per theme (Health, Retention, Agent
budgets, Cron). Each field validates against sensible bounds:

- Times: positive integers, max ~30 days (don't let an admin set a
  retention so long it fills disks).
- Turn budgets: 1..1000 (matches `User::AGENT_MAX_TURNS_RANGE`).
- Threshold ordering: `admin_stuck_warning_seconds` < `run_stale_heartbeat_seconds`.

Show current value next to each input. After update, broadcast a
small "applied immediately, no restart needed" notice so the admin
isn't surprised that the change took effect on the next request.

## Migration approach (rollout)

Land in three commits:

1. **Schema-only**: add the columns with the current values as defaults.
   No code change. No behavior change.
2. **Plumbing**: replace the `CONSTANT = ...` declarations with class
   methods that read the columns. Constants become shims pointing at
   the methods, so existing call sites still work.
3. **UI**: add the admin form section. Now the knobs are live.

Following this order keeps each commit reviewable and reversible.
Reverting commit 3 hides the UI but the knobs still default-equal
the old constants. Reverting commit 2 restores the constants.
Reverting commit 1 drops the columns.

## Acceptance

- [ ] All constants in the inventory have AppSetting columns with
      defaults matching their current values
- [ ] Class-method accessors return the column value (not the cached
      constant), so an `AppSetting.current.update!(...)` call has
      immediate effect
- [ ] Settings page renders all the new knobs under thematic
      sections, with bounds-checking validations
- [ ] Spec coverage: each constant migration has a spec verifying
      that an AppSetting change flips behavior in the dependent code
      path (e.g. `update!(run_stale_heartbeat_seconds: 60)` makes the
      reaper consider a 90s-old heartbeat stale)

## Out of scope

- Per-repo overrides (separate plan).
- Per-user overrides (separate plan).
- DB-driven recurring schedule cadences (separate plan).
- Removing the backwards-compat `CONSTANT` shims — do that as a
  follow-up sweep after caller migration is complete.
