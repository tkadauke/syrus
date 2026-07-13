# Scheduled Tasks

`ScheduledTask` lets operators attach recurring or one-shot agent prompts to a repository. The agent runs on schedule without requiring a GitHub issue.

## Task kinds

### cron

Fires on a recurring schedule defined by a 5-field cron expression (minute hour day-of-month month day-of-week). Cron tasks fire at most once per hour — expressions that would fire more frequently are rejected.

```
# Fire at 9:00 AM UTC every weekday
0 9 * * 1-5
```

The minute field is honored exactly. Syrus evaluates due tasks in UTC hourly windows so repeated poller ticks within the same hour do not double-fire.

### one_shot

Fires once at a future datetime (`fire_at`). After firing, the task moves to `fired` (terminal) state.

## Task states

| State | Meaning |
|---|---|
| `scheduled` | Active, waiting to fire |
| `paused` | Manually paused by the operator |
| `auto_paused` | Paused automatically after too many consecutive failures |
| `fired` | One-shot task has completed (terminal) |

## PR pileup policy

`pr_pileup_policy` controls what happens when the previous fire's PR is still open at the next tick:

| Policy | Behavior |
|---|---|
| `skip` (default) | Don't fire if an open PR already exists |
| `pile` | Fire regardless; multiple open PRs accumulate |
| `replace` | Cancel the old Job and fire a new one |

## Auto-pause

When `consecutive_failure_count` reaches `AppSetting.max_job_failures` (default: 3), the task transitions to `auto_paused`. The operator must unpause the task (via admin UI or Rails console: `task.update!(state: 'scheduled', consecutive_failure_count: 0)`) to re-enable it.

## The "no changes" happy path

Cron tasks should be written so the agent can succeed even if there's nothing to do. The canonical pattern: the agent surveys the repo state, calls `submit_summary` with a one-line note like "No changes needed," and the Job closes with reason `no_changes`. This is counted as a success and does not increment `consecutive_failure_count`.

## CronTemplate

`CronTemplate` is a per-user reusable schedule + prompt configuration that multiple `ScheduledTask` rows can reference. Applying a template copies its `cron_expression`, `prompt`, and `pr_pileup_policy` into the task at creation time. Later edits to the template do not retroactively update existing tasks.

Templates are managed from the user's settings page. Useful when the same survey or maintenance prompt runs across many repositories.

## Variables in prompts

Cron task prompts support these interpolation variables, rendered at fire time:

| Variable | Value |
|---|---|
| `{{repo_slug}}` | `owner/repo` of the target repository |
| `{{last_fired_at}}` | ISO 8601 timestamp of the previous fire (empty on first fire) |

## How tasks fire

`PollScheduledTasksJob` runs every minute. For each due task it:

1. Creates a `Job` with `kind=cron`, linked via `scheduled_task_id`.
2. Creates an initial `Run` whose prompt is pre-rendered at fire time.
3. Enqueues `RunJob` — the standard workflow pipeline takes over from there.

The Job runs on the branch `syrus/scheduled-<task_id>-<job_id>`.

## Per-user scheduling pause

Set `User#scheduling_paused = true` to pause all scheduled tasks for a user without touching individual tasks. `PollScheduledTasksJob` skips paused users entirely. Operators can toggle this via the admin UI; users can toggle it in `/credentials/edit`.
