# Scheduled Tasks

`ScheduledTask` lets operators attach recurring or one-shot agent prompts to a repository. The agent runs on schedule without requiring a GitHub issue.

## Task kinds

### cron

Fires on a recurring schedule stored canonically as an RRULE in UTC. Operators enter natural cadence text such as `Every Monday at 9:00 AM`; five-field cron input (minute hour day-of-month month day-of-week) is also accepted and preserved in `legacy_cron_expression` for audit/compatibility. Recurring tasks fire at most once per hour — expressions that would fire more frequently are rejected.

```
# Fire at 9:00 AM UTC every Monday
Every Monday at 9:00 AM
```

The minute is honored exactly. Syrus evaluates due tasks in UTC hourly windows so repeated poller ticks within the same hour do not double-fire. Fire-time scheduling is deterministic and does not call an AI provider.

### Tiered cadence parsing

`Schedules::CadencePreview` (used by both `ScheduledTask`/`CronTemplate` save
and the `preview_schedule` API endpoints) resolves cadence text in three
tiers:

1. **Strict cron detection** — `Schedules::RecurringSchedule.cron_shaped?`
   only routes input to the cron parser when every one of the five
   whitespace-separated fields independently looks like cron syntax (`*`,
   integers, ranges, steps, comma lists). Five *words* — e.g. `Every day at
   10 am` — are never misrouted into the cron parser just because they
   happen to split into five tokens.
2. **Deterministic natural language** — a small set of supported phrasings
   (`Every day at 10 am`, `Every Monday at 9:00 AM`, `daily at 14:30`, and
   variants) parse without any AI call. Spaced/uppercase meridiem (`10 am`,
   `10 AM`) and compact meridiem (`10am`) are equivalent.
3. **LLM fallback** — only when steps 1–2 both fail, and only for input
   that isn't cron-shaped-but-invalid. `Schedules::CadenceLlmFallback` sends
   the raw text to Gemini (via the operator's own `User#gemini_api_key`) and
   asks for structured intent only (frequency/day/month/hour/minute plus a
   `confidence`/`ambiguous` signal) — never an executable schedule. The
   fallback fails closed (no schedule is saved) when: the user has no
   Gemini key configured, the model reports low confidence or flags the
   request ambiguous, or the returned intent is incomplete. A usable result
   is then run back through the *same deterministic*
   `Schedules::RecurringSchedule.preview(structured_intent:)` path used by
   tier 2, so validation/canonicalization/explanation is identical either
   way and nothing executable ever comes directly from the model.

The scheduler itself (`PollScheduledTasksJob`, `ScheduledTask#next_fire_at`,
`#due?`) only ever reads the already-canonicalized `schedule_expression` —
no LLM call happens at fire time, regardless of which tier resolved the
schedule at save time.

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

Cron tasks should be written so the agent can succeed even if there's nothing to do. The canonical pattern: the agent surveys the repo state, calls the available `submit_summary` MCP tool name with a one-line note like "No changes needed," and the Job closes with reason `no_changes`. This is counted as a success and does not increment `consecutive_failure_count`.

## CronTemplate

`CronTemplate` is a per-user reusable schedule + prompt configuration that multiple `ScheduledTask` rows can reference. Applying a template copies its canonical schedule, prompt, and `pr_pileup_policy` into the task at creation time. Later edits to the template do not retroactively update existing tasks.

Templates are managed from the user's settings page. Useful when the same survey or maintenance prompt runs across many repositories.

### Seeded defaults

A brand-new Syrus installation seeds three starter templates (`CronTemplate::DEFAULT_TEMPLATES`) for the first user created — the installation's bootstrap admin — so `/cron_templates` isn't empty on day one:

| Template | Cadence | Purpose |
|---|---|---|
| Deduplicate code | Weekly, Monday 9:00 AM UTC | Finds and consolidates duplicated logic |
| Keep documentation up to date | Weekly, Wednesday 9:00 AM UTC | Audits docs against recent code changes |
| Increase test coverage | Weekly, Friday 9:00 AM UTC | Adds tests for under-covered, high-risk code |

They're seeded once via `User#seed_default_cron_templates` (an `after_create` callback gated on being the very first `User` row) and are ordinary templates from then on — operators can edit, disable, or delete them like any other. `CronTemplate.seed_defaults_for(user)` is idempotent (`find_or_create_by!` on name), so re-running it is a no-op. Later signups don't get a copy.

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
