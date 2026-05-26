# Plan: per-user magic constants → User columns

_Part of the [magic-constants index](magic-constants-INDEX.md)._

## Context

The smallest cohort of the three. Most knobs are deployment policy
(site-wide) or repository policy (per-repo); only a few are genuinely
per-user. The User model already has the precedent of `agent_max_turns`
overriding the system default — this plan reserves the shape that
upcoming per-user settings should follow.

This plan is **fully forward-looking**: there are no per-user
constants in the codebase today that obviously need to migrate. The
fields below land alongside their respective roadmap items; this
document captures the schema/validation shape so each implementation
plan can drop them in without re-deriving.

## Constants to add as the related work lands

### Claude usage budgets (roadmap: "Claude usage budgets and thresholds")

```sql
ALTER TABLE users
  ADD COLUMN claude_daily_budget_usd_cents      INTEGER NULL,  -- NULL = no cap
  ADD COLUMN claude_weekly_budget_usd_cents     INTEGER NULL,
  ADD COLUMN claude_monthly_budget_usd_cents    INTEGER NULL,
  ADD COLUMN claude_pause_runs_when_over_budget BOOLEAN NOT NULL DEFAULT FALSE;
```

When the threshold is reached and the pause flag is set, the user's
runs queue but don't dispatch until the budget window resets. Sibling
to `AppSetting.runs_paused` but per-user.

### Concurrent-run cap (roadmap: "Multi-layer rate limiting")

```sql
ALTER TABLE users
  ADD COLUMN concurrent_run_cap INTEGER NULL;  -- NULL = use AppSetting site-wide cap
```

Step dispatcher checks this before claiming the next runnable Step.

### Per-user notifications (no existing roadmap entry, but worth noting)

```sql
ALTER TABLE users
  ADD COLUMN notify_on_run_failure  BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN notify_on_pr_review    BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN notify_email           VARCHAR(255) NULL,  -- NULL = email_address
  ADD COLUMN notify_slack_url       TEXT NULL;          -- NULL = no Slack
```

Only relevant once a notification system ships. Listed for future
reference; defer implementation.

## UI

Each field lands in `app/views/credentials/edit.html.erb` (the
existing per-user settings page) under a "Preferences" subsection.
Pattern: input shows current value, faint hint shows the inherited
default (or "no cap" for NULL).

## Migration approach (rollout)

Each future field follows the per-repo plan's three-commit shape:

1. **Schema-only**: add the column(s).
2. **Plumbing**: introduce `User#effective_<setting>` for any field
   with a fallback chain (e.g. `concurrent_run_cap || AppSetting.current.concurrent_run_cap`).
3. **UI**: add the input(s) to credentials/preferences.

No global churn needed; each field is independently shippable.

## Validation (forward shape)

- `claude_*_budget_usd_cents`: NULL or 1..10_000_000 (a $100k/day cap;
  generous floor preventing accidental "0 budget").
- `concurrent_run_cap`: NULL or 1..100.
- `notify_email`: NULL or matches the model's existing email format.
- `notify_slack_url`: NULL or starts with `https://hooks.slack.com/`.

## Out of scope

- Implementing any of the listed fields. They land with their own
  roadmap items; this plan just reserves the shape so the
  implementations stay consistent.
- Per-organization or per-team settings (no Organization model exists).
- Letting users override settings their admin has locked (no concept
  of admin-locked settings today).

## Cross-references

- Roadmap: "Claude usage budgets and thresholds" — owns the Claude
  budget columns
- Roadmap: "Multi-layer rate limiting" — owns `concurrent_run_cap`
