# Magic constants → settings: index

_Captured 2026-05-04. Picks up after a survey of constants in `app/`._

_Status check 2026-05-13: largely not implemented. A small number of
settings already exist (`AppSetting`, `Repository`, and `User` have
some knobs), but the broad site-wide / per-repository / per-user /
recurring-settings migration described here is still future work._

The codebase has accumulated a layer of `CONSTANT = value` declarations
that act as policy decisions in disguise. Some of them are operational
tuning (fine to stay constant), but many are knobs that an operator
will eventually want to twist without redeploying. This series of
plans catalogs them, decides the right scope for each, and migrates
them off magic numbers and onto persisted settings.

## Scope rules

A constant moves to settings when one of these is true:

1. **Per-deployment policy** — value is a household choice, not a code
   property (e.g. "how aggressively do we retry rebases").
   → **Site-wide** (`AppSetting`).
2. **Per-repo policy** — different repos legitimately want different
   values (e.g. one repo wants a deeper `git clone --depth`, another
   wants a lower CI retry cap).
   → **Per-repository** (column on `repositories`).
3. **Per-user policy** — different users have different budgets,
   thresholds, or notification preferences.
   → **Per-user** (column on `users`).

A constant stays a constant when:

- Changing it requires a code review (e.g. regex patterns, validation
  formats, state machine kind lists).
- It's a low-level operational tuning that no operator will ever need
  to override at runtime (e.g. log-buffer flush intervals).
- It expresses a contract with another system (USER_AGENT string,
  protocol version constants).

## The plans

This is split across four follow-up plans, ordered by priority:

1. **[Site-wide constants → AppSetting](magic-constants-site-wide.md)**
   — the largest cohort. Retention windows, agent budgets, stuck-run
   thresholds, summarizer caps, miscellaneous timing tuning. Most
   should land before the per-repo / per-user splits since several
   per-repo settings inherit from site defaults.
2. **[Per-repository constants → Repository columns](magic-constants-per-repository.md)**
   — rebase attempt cap, CI failure cap + window, agent timeout
   override, clone depth, per-repo step opt-outs. Each gets a column
   that defaults to "use the AppSetting" (NULL) and can be overridden.
3. **[Per-user constants → User columns](magic-constants-per-user.md)**
   — GH rate-limit alert threshold, future per-user run budgets and
   notification preferences. Smaller cohort; mostly forward-looking.
4. **[Recurring schedule → DB-driven](magic-constants-recurring-cadence.md)**
   — the `config/recurring.yml` cadences (5min poll, 1min reaper,
   etc) become DB-managed so admins can tune at runtime without a
   deploy. More involved than the others; lower priority but high
   value once the shape settles.

## Inventory snapshot

For reference, the constants the survey turned up, by destination:

| Constant (file) | Current value | Destination |
|---|---|---|
| `Run::STALE_HEARTBEAT_THRESHOLD` | 30.minutes | site-wide |
| `WorkflowWorkspacePruneJob::RETAIN_AFTER_SUCCESS_OR_CANCEL` | 2.hours | site-wide |
| `WorkflowWorkspacePruneJob::RETAIN_AFTER_FAILURE` | 7.days | site-wide |
| Provider transcript retention | 14.days | site-wide |
| `RunDiagnostic::RETAIN_AFTER` | 30.days | site-wide |
| `RunHealthSnapshot::RETAIN_AFTER` | 7.days | site-wide |
| `Invitation::DEFAULT_TTL` | 7.days | site-wide |
| `AgentInvocation::DEFAULT_TIMEOUT_SECONDS` | 30.minutes | site-wide (overridable per-repo) |
| `AgentInvocation::DEFAULT_MAX_TURNS` | 200 | site-wide (already overridable per-user) |
| `PrSummarizer::DEFAULT_TIMEOUT_SECONDS` | 2.minutes | site-wide |
| `PullRequestSummary::MAX_DIFF_BYTES` | 30_000 | site-wide |
| `Steps::Prepare::PER_COMMAND_TIMEOUT` | 10.minutes | site-wide (overridable per-repo) |
| `Steps::Summarize::SUMMARIZE_TURN_BUDGET` | 5 | site-wide |
| `StepDispatcher::MERGEABILITY_RECHECK_DELAY` | 30.seconds | site-wide |
| `Admin::StuckItems::ADMIN_STUCK_THRESHOLD` | 5.minutes | site-wide |
| `DiagnoseRunJob::WARNING_HEARTBEAT` | 5.minutes | site-wide |
| `RunJob::RUNS_PAUSED_RETRY_DELAY` | 30.seconds | site-wide |
| `CronTemplate::MIN_CRON_INTERVAL` / `ScheduledTask::MIN_CRON_INTERVAL` | 1.hour | site-wide |
| `PollRebaseJob::REBASE_ATTEMPT_CAP` | 5 | per-repo (with site default) |
| `PollPullRequestJob::CI_FAILURE_CAP` | 3 | per-repo (with site default) |
| `PollPullRequestJob::CI_FAILURE_WINDOW` | 24.hours | per-repo (with site default) |
| `WorkflowWorkspace::CLONE_DEPTH` | 50 | per-repo (with site default) |
| `IngestPolicy::SKIP_LABEL` | "syrus-skip" | per-repo (already done for trigger_label; same pattern) |
| Recurring schedule cadences (`config/recurring.yml`) | 1min/5min/2h/daily | site-wide DB-driven (own plan) |

Things that **stay constant** (don't migrate):

- `Repository::GITHUB_NAME` (regex), `User::API_TOKEN_PREFIX`,
  `Run::TRIGGER_KINDS`, `Step::KINDS`, `Job::KINDS`, `*::PATH_ENCODE_PATTERN`,
  `GithubClient::USER_AGENT`, `GitRunner::AUTH_URL_PATTERN`,
  `GithubClient::FAILED_CONCLUSIONS`,
  `Steps::Base::LOG_FLUSH_BYTES` / `LOG_FLUSH_INTERVAL`,
  `GitRunner::OUTPUT_TAIL_LIMIT`, `CaptureRunDiagnostic::ENV_ALLOWLIST*`,
  `Steps::Base::AGENTIC_KINDS`.

## Cross-cutting design rule

Every constant migration follows the same shape:

1. Add a column to the destination table with the current constant as
   the default. Schema change is non-destructive.
2. Add a class method or a settings accessor (e.g. `AppSetting.run_stale_heartbeat_threshold`)
   that reads the column.
3. Replace `CONSTANT` references in code with the accessor. Keep the
   old constant name pointing at the accessor as a tiny shim so spec
   files don't churn.
4. Add a row in the admin Settings page (or `/repositories/:id/edit`,
   or `/credentials/edit`) to surface the knob.
5. Spec covers: default behavior unchanged when the column is at its
   default; behavior changes when the column is updated.

This keeps each migration small and reviewable, and produces no
behavior change at landing time.
