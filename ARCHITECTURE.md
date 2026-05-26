# Syrus architecture

_Last reviewed: 2026-05-03 (against `main`)._

**Audience.** A new contributor or returning maintainer who's already
read `README.md` and wants the full mental model. CLAUDE.md is the
agent-facing summary; this document is the human reference. Where the
two overlap, this one is the canonical detail and CLAUDE.md is the
abridged version. Forward-looking ideas live in `ROADMAP.md` and are
only mentioned here as cross-references.

**Conventions.** `Job` and `Run` capitalized refer to the AR models;
lowercased _job_ ("the thread") and _run_ ("an attempt") refer to the
domain concepts. File paths are repo-relative.

## Contents

- [Stack](#stack)
- [The big picture](#the-big-picture)
- [Domain model](#domain-model) — Job, Run, JobLog, Repository, User, ScheduledTask, ClaudeSession
- [Recurring schedule](#recurring-schedule)
- [Per-poller flow](#per-poller-flow) — issue ingest, PR feedback, rebase, scheduled tasks, reaping
- [Per-Run pipeline](#per-run-pipeline) — initial/follow-up path and rebase path
- [End-to-end GitHub workflow](#end-to-end-github-workflow)
- [Services](#services)
- [MCP sidecar](#mcp-sidecar)
- [Failure recovery](#failure-recovery)
- [UI surface](#ui-surface)
- [Deployment topology](#deployment-topology)
- [What's intentionally not here](#whats-intentionally-not-here)

## Stack

- Rails 8.1.3 · Ruby 3.2.3
- SQLite (dev/test) · MySQL (production)
- **Solid Queue** for background jobs · **Solid Cache** · **Solid Cable**
  for Turbo Streams broadcasts
- **Tailwind** via `tailwindcss-rails` · **Turbo Streams + Stimulus** for
  the web UI (no React)
- **Octokit** for the GitHub API
- **AASM** for state machines on `Job` and `Run`
- **`claude-code` CLI** as the agent (subprocess; see
  [Per-Run pipeline](#per-run-pipeline) for invocation details)

## The big picture

Polling drives everything — Syrus never receives a webhook. Every
external interaction (GitHub issue ingestion, PR comment ingestion,
rebase trigger detection) is initiated by a recurring job that fans
out to per-target jobs.

```
                  ┌─────────────────────────────────────────┐
                  │         Solid Queue recurring           │
                  │  (config/recurring.yml — every 1/5 min) │
                  └─────────────────────┬───────────────────┘
                                        │
       ┌──────────────────┬─────────────┼──────────────┬──────────────────┐
       ▼                  ▼             ▼              ▼                  ▼
PollAllRepos…    PollAllPullRequests… PollAllMergeStates… PollScheduledTasks… ReapStaleRuns…
  (fan-out)         (fan-out)          (fan-out)        (in-process)      (sweeper)
       │                  │             │                  │                  │
       ▼                  ▼             ▼                  ▼                  ▼
PollRepositoryJob  PollPullRequestJob  PollMergeStateJob ScheduledTaskFire marks running
  per repo           per Job-with-PR    per Job-with-PR  service per task   Runs as failed
       │                  │             │                  │                  ▼
       │       creates    │   creates   │   creates        │              (no enqueue)
       └──────────────────┴─────────────┴──────────────────┘
                                        │
                                        ▼
                                 Job#after_create_commit
                                 Run#after_create_commit
                                        │
                                        ▼
                                  RunJob.perform_later
                                        │
                                        ▼
                       JobWorkspace + AgentInvocation +
                       MCP sidecar + PullRequestOpener
```

The model callbacks (`Job#after_create_commit → create_initial_run`,
`Run#after_create_commit → enqueue_run_job`) are what actually wire
"a poller created a row" to "a worker picks up the run." The pollers
never call `RunJob.perform_later` directly. `ReapStaleRunsJob` does
not enqueue runs at all — it transitions stuck `running` Runs to
`failed` and cleans up their worktrees.

`Job` is the thread (one per GitHub issue or per scheduled-task fire).
`Run` is the attempt (one per agent invocation). A Job has many Runs.

## Domain model

### Job — the *thread*

Lives in `app/models/job.rb`. One `Job` per GitHub issue (or per cron
fire). Carries the GitHub identifiers and lifecycle state.

| Column | Meaning |
|---|---|
| `kind` | `"issue"` (created from a labeled issue) or `"cron"` (created from a `ScheduledTask` fire) |
| `state` | `"open"` ⇄ `"closed"` (AASM) |
| `repository_id`, `user_id` | scope |
| `issue_number` | nullable for cron jobs |
| `issue_title`, `issue_body` | cached at ingest |
| `branch_name` | `syrus/issue-{N}-{job_id}` (issue Jobs) or `syrus/scheduled-{task_id}-{job_id}` (cron Jobs); assigned by the first Run's `JobWorkspace.setup` and persisted on the Job for follow-up Runs to reuse |
| `pr_number` | the Syrus-opened PR, if any |
| `external_pr_number` | the *preempted* path — see below |
| `pr_mergeable`, `pr_mergeable_checked_at` | latest from GitHub; updated by `PollRebaseJob` |
| `failure_count` | consecutive non-rebase Run failures; reset on reopen; threshold `AppSetting.max_job_failures` auto-closes the thread with reason `too_many_failures` |
| `closure_reason` | string tag explaining why the thread closed (see table below) |
| `last_seen_comment_at` | watermark for the PR-feedback poller |
| `last_ci_handled_sha` | watermark for CI-failure follow-ups |
| `scheduled_task_id` | nullable; set on cron Jobs |

`closure_reason` values:

| Value | Meaning |
|---|---|
| `nil` | Job is open |
| `cancelled` | operator cancelled active runs and closed the thread |
| `replaced` | operator clicked Restart, which closes-and-respawns |
| `replaced_by_scheduled_task` | a cron fire with `pr_pileup_policy=replace` superseded an earlier Job |
| `too_many_failures` | `failure_count` hit `AppSetting.max_job_failures` |
| `no_changes` | a cron Run finished with an empty diff and a one-line summary |
| `preempted` | the issue already had a human-opened PR when we ingested it |

States and transitions:

```ruby
state :open, initial: true
state :closed

event :close   { from: :open,   to: :closed }
event :reopen  { from: :closed, to: :open }   # clears closure_reason, finished_at, failure_count
```

### Run — the *attempt*

Lives in `app/models/run.rb`. One per agent invocation. Owns the
prompt, the agent metadata, and the resulting diff.

| Column | Meaning |
|---|---|
| `state` | AASM (see diagram below) |
| `trigger_kind` | what the Run is *for* (see table below) |
| `prompt` | the full prompt the agent sees |
| `agent_turns`, `agent_outcome`, `agent_diff`, `head_sha` | populated from the stream-json `result` event + post-run git capture |
| `agent_pr_title`, `agent_pr_body`, `agent_summary` | written by the agent via the MCP `submit_summary` tool |
| `parent_session_id` | for `resume` Runs: the prior Run's `claude --resume` session id (links into `ClaudeSession`, not directly to a parent Run row) |
| `last_heartbeat_at` | bumped on every `JobLog` write; used by `ReapStaleRunsJob` |

```ruby
state :queued, initial: true
state :running, :succeeded, :failed, :cancelled

event :start    { from: :queued,           to: :running   }
event :succeed  { from: :running,          to: :succeeded }
event :fail     { from: [:queued, :running], to: :failed  }
event :cancel   { from: [:queued, :running], to: :cancelled }
```

`cancelled` is reached three ways: the operator clicks Cancel/Restart
on the Job page (which calls `Job#cancel_active_runs_and_close!`), a
cron fire with `pr_pileup_policy=replace` cancels the prior Job's
active Runs, or `RunJob`'s re-entrancy guard fires (a worker entering
`perform` and finding the Run already `running` — symptom of a crashed
prior worker — fails it rather than restarting). The SIGTERM/grace-
period case ends in `failed` via `ReapStaleRunsJob`, not `cancelled`.

`trigger_kind` is one of:

| Kind | Triggered by | Notes |
|---|---|---|
| `initial` | `Job` create (issue Jobs auto-spawn the first Run; cron Jobs do it via `PollScheduledTasksJob`) | makes the branch + opens the PR |
| `pr_comment` | `PollPullRequestJob` finds new review comments since `last_seen_comment_at` | reuses the same branch |
| `ci_failure` | `PollPullRequestJob` finds failing checks on the head SHA | reuses the same branch; gated on `last_ci_handled_sha` |
| `rebase` | `PollRebaseJob` finds `pr.mergeable == false` and we control the head | rewrites history rather than commits; force-pushes |
| `retry` | operator: "Run again" | new Run on the existing branch |
| `manual` | operator: explicit manual prompt | freeform |
| `resume` | operator: "Resume failed run" | continues a prior Run via `claude --resume` from `ClaudeSession.transcript_jsonl` |

State changes broadcast Turbo refreshes; see [UI surface](#ui-surface)
for how broadcasts land in the browser.

### JobLog — the transcript

Append-only chunks per Run (`belongs_to :run`). `RunJob#log`,
`AgentInvocation`, the MCP sidecar, and `JobWorkspace` all write to
it. Unique on `(run_id, sequence)`. `before_update` raises
`ReadOnlyRecord` — once written, never edited.

`broadcasts_to` per JobLog drives the live transcript on the job page.

### Repository

Unique on `(user_id, owner, name)`: the same GitHub repo can be
registered by multiple Syrus users, but not twice by the same user.
Per-user is the natural scope because Syrus uses each user's own
GitHub PAT and Claude OAuth token — there is no shared "Syrus account"
on GitHub today. Carries `default_branch`, `polling_enabled`,
`trigger_label` (default `"syrus"`), `archived_at`. Archive blocks
polling even if `polling_enabled` is true.

### User

Encrypted attributes for `claude_oauth_token` and `github_token`
(Active Record Encryption — `RAILS_MASTER_KEY` is required to read
them). `agent_max_turns` is the per-user ceiling on `claude
--max-turns`; `0` (or `nil`) means "no `--max-turns` flag" — the
30-minute per-Run wall-clock timeout still applies. The first user
to sign up is auto-promoted to admin (bootstrap convenience, not a
core architectural concern).

### ScheduledTask

Cron-style schedule (5-field expression, validated to fire at most
once per hour) or one-shot `fire_at`, attached to a Repository.
Periodically spawns a cron `Job` with a pre-rendered prompt
(`{{repo_slug}}`, `{{last_fired_at}}`, etc. expanded at fire time).
A random `minute_offset` is seeded at creation so two tasks with the
same nominal schedule don't collide on the wall clock.

This is the single user-facing recurring-work model. Chat-created
recurring schedules requested through `schedule_recurring` are confirmed
into `ScheduledTask(kind: "cron")` rows and fire through the same
`PollScheduledTasksJob` / `ScheduledTaskFire` path as schedules created
from the operator UI. Solid Queue's internal `RecurringTask` records are
only queue scheduler plumbing and do not represent operator prompts.

`pr_pileup_policy` controls what happens when a prior cron-Job's PR
is still open at the next fire:

| Value | Behavior |
|---|---|
| `skip` (default) | don't fire; bump `last_fired_at` only |
| `pile` | fire anyway; previous Job and its PR remain |
| `replace` | cancel the prior Job's active Runs and close it (`closure_reason=replaced_by_scheduled_task`), then fire |

A `consecutive_failure` counter on the task auto-pauses the schedule
once `AppSetting.max_job_failures` is hit; the operator must click
Resume to re-enable.

### ClaudeSession

One row per Run that completes a `claude` invocation, holding the
`session_id` and the JSONL transcript path on disk. Used by `resume`
Runs to call `claude --resume <session_id>`. Retained for **14 days
after the parent Run reaches a terminal state**
(`ClaudeSession::RETAIN_AFTER_TERMINAL`), then deleted by
`ClaudeSessionPruneJob` (daily at 3am). Sessions whose parent Run is
still `queued` or `running` are never pruned, regardless of age.

### The "preempted" path

Special case worth calling out: when `PollRepositoryJob` ingests an
issue that already has a human-opened PR linked to it, Syrus records
the Job with `external_pr_number` set to that PR's number,
`closure_reason="preempted"`, and `state=closed` from the start — no
agent work is scheduled. The point is awareness (the operator sees
the issue in the dashboard with a "preempted" pill) and the option
to keep the PR mergeable: `PollAllMergeStatesJob` still checks
external PRs whose head we control, even on closed Jobs. See
`app/jobs/poll_repository_job.rb` for the detection logic and
`app/jobs/poll_all_merge_states_job.rb` for why merge-state polling
deliberately includes preempted Jobs.

## Recurring schedule

`config/recurring.yml`:

| Job | Cadence | What it does |
|---|---|---|
| `PollAllRepositoriesJob` | every 5 min | Fans out to `PollRepositoryJob` per active repo |
| `PollAllPullRequestsJob` | every 5 min | Fans out to `PollPullRequestJob` per Job-with-PR |
| `PollAllMergeStatesJob` | every 5 min | Fans out to `PollMergeStateJob` per Job-with-PR |
| `PollScheduledTasksJob` | every 1 min | Finds due `ScheduledTask`s; fires via `ScheduledTaskFire` |
| `ReapStaleRunsJob` | every 1 min | Marks Runs whose heartbeat is older than 30 min as `failed` |
| `ClaudeSessionPruneJob` | daily 3am | Drops sessions for terminal Runs older than the retention window |

Plus one Solid Queue housekeeping entry, `clear_solid_queue_finished_jobs`,
which is production-only because dev wipes the Solid Queue tables
often enough on its own. It runs hourly and `delete_all`s finished
job rows in batches.

## Per-poller flow

### Repository ingestion (issue → Job → Run)

```
PollRepositoryJob (per repo, serialized via SolidQueue concurrency key)
  → GithubClient.for(repository:, user:).issues_with_label(slug, trigger_label)
  → IngestPolicy filters (skip closed issues, PRs, syrus-skip label)
  → For each surviving issue:
      Job.find_or_create_by(repository, issue_number, state: open)
      Job#after_create_commit → create_initial_run
        Run(trigger_kind: "initial", state: "queued") created
        Run#after_create_commit → enqueue_run_job
          RunJob.perform_later(run_id) hits SolidQueue
```

The initial Run is autostart for issue-kind Jobs only. Cron-kind Jobs
have their initial Run created explicitly by `PollScheduledTasksJob`
with a pre-rendered prompt (so `{{date}}` and friends reflect fire
time, not RunJob start time).

The dedup is the `Job.find_or_create_by(repository, issue_number,
state: "open")` with the partial unique index — a closed thread plus
an open thread for the same issue is allowed (retry-after-close).

### PR feedback (`pr_comment`, `ci_failure`)

```
PollAllPullRequestsJob
  → PollPullRequestJob per open Job with pr_number
      → fetch issue comments, review comments, reviews, checks
      → filter to events newer than last_seen_comment_at
      → if any new comment exists:
          Run.create!(trigger_kind: "pr_comment",
                      prompt: Prompts::PrFeedback.new(...).to_s)
      → if checks on pr.head.sha are failing AND sha != last_ci_handled_sha:
          Run.create!(trigger_kind: "ci_failure",
                      prompt: Prompts::CiFailure.new(...).to_s)
      → bump last_seen_comment_at / last_ci_handled_sha as watermarks
```

There is no author filter on the PR-comment path today: every Syrus
deployment runs under a single operator's PAT, so any comment that
isn't from "us" (i.e. anyone else commenting on the PR) is something
we want to act on. If/when Syrus grows a separate bot identity, a
configurable skip-by-login filter will go here.

### Rebase loop

```
PollAllMergeStatesJob (includes preempted threads that still need merge-state checks)
  → PollMergeStateJob per Job with pr_number OR external_pr_number
      → fetch PR, persist pr_mergeable + pr_mergeable_checked_at
      → bail if merged / closed / mergeable in (true, nil)
      → bail if head is from a fork (we don't push)
      → bail if a rebase Run is already active
      → bail if rebase attempt cap reached
      → AutoRebase.try first (non-interactive `git rebase`):
          clean? force-push, mark Job mergeable, done — no Run created
          conflict? fall through to:
      → Run.create!(trigger_kind: "rebase")
```

The fast path through `AutoRebase` matters: most rebases are
mechanical and don't need the agent. Only conflicts that require
judgment escalate to a Run. See [Services](#services) for details.

### Scheduled tasks

```
PollScheduledTasksJob (every minute)
  → alive ScheduledTasks for active repositories and unpaused users
      whose scheduled fire time has arrived
      → ScheduledTaskFire.call(task)
        → render prompt (variable expansion: {{date}}, etc.)
        → apply pr_pileup_policy if a prior cron-Job's PR is still open
        → Job.create!(kind: "cron", scheduled_task_id: task.id, ...)
        → Run.create!(trigger_kind: "initial", prompt: rendered)
        → bump last_fired_at, last_successful_fire_at, etc.
```

### Stale Run reaping

```
ReapStaleRunsJob (every minute)
  → Run.running.where("last_heartbeat_at < ?", 30.minutes.ago)
      → mark as failed (agent_outcome: "worker_died")
      → JobWorkspace.cleanup
```

The 30-minute threshold is generous on purpose: claude-code can be
quiet for several minutes during long thinking phases. The heartbeat
is bumped on every `JobLog#log` write — not on a separate timer — so
"agent producing transcript output" implicitly counts as alive.

## Per-Run pipeline (`RunJob#perform`)

There are two pipelines depending on `trigger_kind`. The
**initial / follow-up** path (everything except `rebase`) edits files
and produces a diff. The **rebase** path rewrites history and
force-pushes; it skips diff capture and PR opening entirely.

Both pipelines share the front matter:

1. Find `@run`; bail if `Run.terminal?`. Rebase Runs ignore the
   Job-closed guard; non-rebase Runs bail if `@job.closed?`.
2. Re-entrancy guard: if `@run` is already `running`, fail it
   immediately rather than starting again — the only way that state
   arises is recovery from a crashed prior worker.
3. AASM `start!`; record `started_at`.
4. `JobWorkspace.setup(@run)`:
   - Fresh shallow clone (`--depth 50`) at `$SYRUS_DATA_ROOT/runs/<run_id>/`.
     No shared state across concurrent Runs — each gets its own isolated clone.
   - Always clones the default branch so it is a local ref for three-dot diff.
   - Branch: fetches and checks out existing for follow-up Runs; creates new for initial Runs.
5. Compose the prompt via the appropriate `Prompts::*` class
   (`Initial`, `PrFeedback`, `CiFailure`, `Rebase`, `Resume`, or
   the pre-rendered `ScheduledTask` body).
6. Spawn the agent via `AgentInvocation`:
   - `claude --print --output-format stream-json --dangerously-skip-permissions`
   - `--max-turns N` only if `User#agent_max_turns > 0` (omitted when
     `0` or `nil`).
   - `--mcp-config` slotted between flags (never adjacent to the
     prompt — it's variadic).
   - 30-minute wall-clock cap (`AgentInvocation::DEFAULT_TIMEOUT_SECONDS`)
     enforced by killing the subprocess if exceeded.
   - `SyrusMcp::Sidecar` runs in-process; agent talks to it over stdio.
   - Stream-json events: assistant text → `JobLog`; final `result`
     event → metadata (`agent_turns`, `agent_outcome`, `final_text`,
     `session_id`).
7. Persist the agent metadata on the Run.

### Initial / follow-up tail (everything except rebase)

8. `commit_agent_changes` — catch-all if the working tree has
   uncommitted changes after the agent exited.
9. `capture_diff_against_default` — three-dot diff vs default branch
   (`git diff main...HEAD`); raises if empty (treated as Run failure
   for issue Jobs, treated as success-with-`no_changes` for cron Jobs).
10. Push the branch via the per-user GitHub token.
11. `open_pull_request_if_missing`, in priority order:
    1. Agent submitted via the MCP `submit_summary` tool → use
       `agent_pr_title` / `agent_pr_body`.
    2. `PrSummarizer` second-shot `claude` call → `{title, body}` JSON.
    3. Templated default.

    Then `PullRequestOpener.open(...)`.
12. AASM `succeed!`; record `finished_at`.

### Rebase tail

8. Force-push the rebased branch (`git push --force-with-lease`).
9. AASM `succeed!`. No commit, no diff capture, no PR opening — the
   PR already exists; we've just moved its head SHA.

### Cleanup and error handling

- `ensure`: `JobWorkspace.cleanup` deletes the run directory (`rm -rf $SYRUS_DATA_ROOT/runs/<run_id>`).
- On exception: AASM `fail!`; record `agent_outcome`; `Job#record_run_failure!`
  for non-rebase Runs (rebase failures don't bump `failure_count`).
- On SIGTERM: Solid Queue's graceful-shutdown timeout lets the current
  Run finish if it can. If the worker is killed mid-flight (K8s deploys,
  OOM), the Run is left in `running`; `ReapStaleRunsJob` transitions it
  to `failed` after 30 min of heartbeat silence.

## End-to-end GitHub workflow

What happens to a single labeled issue, from label to merge:

1. **Label applied** on a registered repo's issue (default label
   `syrus`).
2. **Within 5 min**, `PollRepositoryJob` for that repo finds the issue.
   `IngestPolicy` lets it through (open, not a PR, no `syrus-skip`
   label, no existing open `Job`). A `Job(state: open, kind: issue)`
   is created.
3. **`Job#after_create_commit`** spawns the initial `Run(trigger_kind:
   initial, state: queued)`.
4. **`Run#after_create_commit`** enqueues `RunJob.perform_later(run.id)`.
5. **A worker picks up the RunJob**:
   - Sets up the worktree on a fresh branch `syrus/issue-{N}-{job_id}`.
   - Composes the initial prompt from the issue title + body via
     `Prompts::Initial`.
   - Invokes `claude-code` with the MCP sidecar attached.
   - Agent works: edits files, commits, optionally calls
     `submit_summary` via MCP.
   - Worker captures diff, pushes branch, opens PR (using agent's
     summary if provided; falling back through `PrSummarizer` to
     templated copy otherwise).
   - Run transitions to `succeeded`. Job stays open.
6. **PR is now open**. From this point:
   - `PollPullRequestJob` watches every 5 min for new review comments
     on this Job. New comment → `pr_comment` follow-up Run on the
     same branch.
   - `PollPullRequestJob` watches CI checks. Failing check on the
     head SHA → `ci_failure` follow-up Run on the same branch.
   - `PollMergeStateJob` watches mergeability. Unmergeable + we
     control the head → `PollRebaseJob` may create a `rebase` Run
     that re-anchors the branch.
7. **PR is merged.** Today: nothing automatic. The Job stays open
   until the operator clicks "Close thread", or until
   `failure_count` from later runs trips the auto-close threshold.

The thread close → branch deletion → worktree cleanup chain is
intentionally manual today; auto-close-on-merge is a future idea
adjacent to "Auto rebase-and-merge on approval" in `ROADMAP.md`.

## Services

Core (the agent loop):

| Service | Purpose |
|---|---|
| `JobWorkspace` | Fresh per-Run clone at `$SYRUS_DATA_ROOT/runs/<run_id>/`. Default root `~/.syrus` (override with `SYRUS_DATA_ROOT`). Clones never live inside `Rails.root` — protects the operator's checkout from agent chdir mishaps. |
| `AgentInvocation` | Spawns `claude-code` via `Open3.popen2e`, parses stream-json, threads stdout chunks into `JobLog`, returns a `Result` struct (turns, outcome, exit status, final text, session id). Wires the MCP sidecar. Enforces the 30-minute wall-clock timeout. |
| `SyrusMcp::Sidecar` | In-process MCP server the agent talks to over stdio. Exposes `submit_summary`. See [MCP sidecar](#mcp-sidecar). |
| `Prompts::*` | One class per Run kind: `Initial`, `PrFeedback`, `CiFailure`, `Rebase`, `Resume`, `ScheduledTask`, plus `PullRequestSummary` for `PrSummarizer` and `SubmitSummaryInstructions` mixed into prompts that should expose the MCP tool. |

Git and GitHub:

| Service | Purpose |
|---|---|
| `GitRunner` | Subprocess wrapper around `git` that streams stdout/stderr into `JobLog` and redacts `https://x-access-token:TOKEN@github.com/...` URLs from error messages. |
| `GithubClient` | One Octokit client per user. Wraps `issues_with_label`, `pull_request`, `pull_request_comments`, `pull_request_reviews`, `combined_status_for_ref`, etc. Surfaces `Octokit::TooManyRequests` to callers (logged then re-raised). |
| `PullRequestOpener` | Octokit `create_pull_request` with retry on transient failures. |
| `AutoRebase` | See subsection below. |

Policy and pipeline glue:

| Service | Purpose |
|---|---|
| `IngestPolicy` | The "should we make a Job for this issue?" filter — skips PRs, closed issues, the `syrus-skip` label, etc. |
| `PrSummarizer` | Second-shot `claude` call (`max_turns: 1`, tmpdir-rooted) that takes issue + diff and returns `{title, body}` JSON. Tier 2 fallback when the agent didn't call `submit_summary`. |
| `ScheduledTaskFire` | Encapsulates the "fire a due ScheduledTask" decision: pile-up policy, prompt rendering, Job + Run creation, watermark bumping. |

### AutoRebase

Most rebases are mechanical: PR was opened, base branch moved, no
overlapping edits. Spinning up an entire agent Run for those is
wasteful — `claude` boot-up alone costs more than the rebase itself.

`AutoRebase.try` checks out the PR's branch in a worktree, runs
`git rebase origin/<base>` non-interactively, and:

- **Clean rebase** → force-pushes the rebased branch, marks the Job
  mergeable, and `PollRebaseJob` skips creating a `rebase` Run. The
  whole thing happens inside the polling job; no worker handoff.
- **Conflict** → aborts the rebase, leaves the worktree clean, and
  returns false. `PollRebaseJob` falls through to creating an agent
  `rebase` Run, which gets the conflict context in its prompt and
  resolves it with judgment.

This is the single biggest cost optimization in the pipeline. Worth
preserving — any change to rebase handling should keep the fast path.

## MCP sidecar

`AgentInvocation` constructs a `SyrusMcp::Sidecar` per Run and writes
an MCP config tempfile pointing the agent at it. Today's tool surface:

- `submit_summary(pr_title:, pr_body:, summary:)` — records
  agent-authored PR copy on the Run. Read tier-1 by `RunJob` when
  opening the PR.

The sidecar lives in-process with Rails, so tool handlers are plain
ActiveRecord calls scoped to the running Run via
`Thread.current[:syrus_current_run]`. No network, no auth plumbing.

`bin/syrus-mcp-sidecar` is the binstub `claude` actually spawns; it
boots Rails and hands stdio to `SyrusMcp::Sidecar`. SIGTERM is trapped
to drain cleanly. Roadmap items under **Agent ↔ Syrus MCP sidecar**
in `ROADMAP.md` describe the broader tool-surface vision.

## Failure recovery

Several layers, each catching different failure modes:

1. **`AgentInvocation` timeout** — 30-minute wall-clock cap (and
   `--max-turns` for users with `agent_max_turns > 0`). Either kills
   the `claude` subprocess and returns a `Result` with `timed_out:
   true`. `RunJob` calls `fail!`.
2. **`RunJob#ensure`** — always calls `JobWorkspace.cleanup`. Cleanup
   failures are logged but don't suppress the original exception.
3. **Heartbeat reaper** — `RunJob#log` bumps `last_heartbeat_at` on
   every `JobLog` write. `ReapStaleRunsJob` runs every minute and
   fails any `running` Run whose heartbeat is older than 30 min
   (worker died, OOM, K8s SIGKILL past grace period). The 30-minute
   window is generous on purpose: `claude` can be quiet for several
   minutes during long thinking phases.
4. **Re-entrancy guard** — distinct from the terminal-state bailout.
   On entry, `RunJob#perform` first bails silently if the Run is
   already `terminal?` (idempotent retry). Only if the Run is
   already in `running` state — which only happens when the prior
   worker crashed — does it call `fail!` and skip execution.
5. **Resume** — operator opens a Run with `trigger_kind: "resume"`,
   `parent_session_id` pointing at a prior `ClaudeSession`. RunJob
   copies the JSONL transcript back into Claude's per-project path
   on the new worktree and passes `--resume <session_id>`. The
   `Prompts::Resume` body tells the agent it was interrupted and to
   re-orient via `git status` / `git log`.
6. **`failure_count` and auto-close** — `Job#record_run_failure!` is
   called by `RunJob` after a non-rebase Run fails. It increments
   `failure_count`; if the result hits `AppSetting.max_job_failures`,
   the Job auto-closes with `closure_reason="too_many_failures"`.
   Reopening a Job resets the counter. **Rebase Run failures don't
   count** — they're independent of the issue's progress and a
   transient base-branch tangle shouldn't burn through the failure
   budget. Rebase Runs have their own per-PR attempt cap inside
   `PollRebaseJob`.

## UI surface (what shows up where)

- **`/`** — dashboard: per-user job table, status pills,
  manual-poll button, search filters.
- **`/repositories`** — registry: add/remove, archive, toggle
  polling, per-repo trigger label, manual poll, scheduled tasks.
- **`/repositories/:id`** — show page: metadata, recent jobs,
  GitHub link.
- **`/jobs/:id`** — the operational hub for a single thread:
  live-streaming transcript per Run, agent diff, PR + branch links,
  action buttons (`run_again`, `restart`, `cancel`, `reopen`,
  `poll_feedback`, `rebase`, `check_mergeability`, `resume`,
  `stop_run`).
- **`/scheduled_tasks`** — cron task management.
- **`/credentials/edit`** — paste GH PAT and Claude OAuth token
  (write-only, never echoed).
- **`/settings`** — admin toggles (signups open, max job failures);
  redirects non-admins to credentials.
- **`/invitations`** — admin invite flow.

Realtime updates everywhere via Turbo Streams. `Job` and `Run` use
`broadcasts_refreshes` + Turbo morph (`turbo_refreshes_with method:
:morph`) so the worker's DB writes patch the operator's browser
without a refresh. There's also a per-user `"jobs"` stream so the
dashboard updates as new Jobs appear. The transcript element on the
job show page is `data-turbo-permanent` so morphs preserve scroll
position. Dev mode uses `solid_cable` (NOT `async`) so cross-process
broadcasts work between web and worker.

## Deployment topology

- Two Kubernetes Deployments behind one Service: `syrus-web` (Puma)
  and `syrus-worker` (`bin/jobs`). The worker process supervises separate
  Solid Queue pools for `runs`, `chat`, and `default` jobs. MySQL runs in
  its own pod.
- Traefik ingress at `syrus.internal.green-acres.estate`.
- Persistent volume mounted at `$SYRUS_DATA_ROOT` (default
  `/home/rails/.syrus`) on worker pods, holding active per-Run clones
  at `runs/<run_id>/` and AutoRebase clones at `auto-rebase/<job_id>/`.
  Web pods don't need this volume.
- Two clusters: staging (default kubeconfig) and production
  (`~/.kube/config-production`). Diagnostic recipes are in `CLAUDE.md`
  under "Debugging staging / production via kubectl".
- Image is built `linux/amd64` for the homelab NUC; see CLAUDE.md
  "Deploy target" for the Colima/Rosetta build playbook.

## What's intentionally not here

These belong to `ROADMAP.md`; only their current status is recorded:

- **Sandboxed Docker-per-Run isolation.** Today: fresh per-Run clone
  on the worker filesystem; the agent is trusted not to escape.
- **Public REST / MCP API.** The sidecar is internal-only; there's no
  external auth surface.
- **Quality graders / visual graders / agent-authored test plans.**
  Today the only gate on a Run's output is "diff is non-empty."
- **Global rate limiting.** Today only Solid Queue's per-key
  concurrency: per-repo polling, per-Job PR/rebase polling, per-Job
  RunJob serialization. No tenant-wide or process-wide cap.
- **Auto rebase-and-merge on approval.** Today a human merges; Syrus
  doesn't watch review state.

See `ROADMAP.md` for design notes on each.
