# Syrus architecture

_Last reviewed: 2026-07-01._

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
- [Domain model](#domain-model) — Job, Epic, Workflow, Step, Run,
  JobLog, Repository, User, ScheduledTask, CronTemplate
- [Recurring schedule](#recurring-schedule)
- [Per-poller flow](#per-poller-flow) — issue ingest, PR/chat feedback, rebase, scheduled tasks, reaping
- [Per-Workflow pipeline](#per-workflow-pipeline) — materialized step chains and Run execution
- [End-to-end GitHub workflow](#end-to-end-github-workflow)
- [Services](#services)
- [MCP sidecar](#mcp-sidecar)
- [Chat sidecar and workspaces](#chat-sidecar-and-workspaces)
- [Failure recovery](#failure-recovery)
- [UI surface](#ui-surface)
- [Deployment topology](#deployment-topology)
- [What's intentionally not here](#whats-intentionally-not-here)

## Stack

- Rails 8.1.3 · Ruby 3.2.3
- SQLite (dev/test) · MySQL (production)
- **Solid Queue** for background jobs · **Solid Cache** · **Solid Cable**
  for browser app events
- **Tailwind** via `tailwindcss-rails` · **React** for the web UI
- **Go CLI** under `cli/` for terminal chat, inbox review, checkout,
  test-plan, approval, identity, and Job/Epic/repository/schedule
  workflows through the app API
- **Electron desktop shell** under `desktop/` for a menubar inbox,
  native notifications, checkout/approval shortcuts, and local
  repository path preferences against the same app API
- **Octokit** for the GitHub API
- **AASM** for state machines on `Job`, `Workflow`, `Step`, and `Run`
- **Claude Code** and **Codex** as agent providers (subprocesses behind
  `AgentProviders::*`; see [Per-Workflow pipeline](#per-workflow-pipeline))

## The big picture

Polling drives everything — Syrus never receives inbound GitHub callbacks. Every
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
PollRepositoryJob  PollPullRequestJob  PollMergeStateJob ScheduledTaskFire reaps/requeues
  per repo           per Job-with-PR    per Job-with-PR  service per task   orphaned Runs
       │                  │             │                  │                  ▼
       │       creates    │   creates   │   creates        │              (recovery)
       └──────────────────┴─────────────┴──────────────────┘
                                        │
                                        ▼
                         ClassifyIssueJob / advance_after_triage
                       StepDispatcher + Run#after_create_commit
                                        │
                                        ▼
                                  RunJob.perform_later
                                        │
                                        ▼
                       WorkflowWorkspace + AgentProviders::* +
                       MCP sidecar + PullRequestOpener
```

The state-transition callback and dispatcher (`Job#advance_after_triage`
→ `create_initial_run_if_needed`, `StepDispatcher.start_workflow`, and
`Run#after_create_commit → enqueue_run_job`) are what wire "a poller
created a Job" to "a worker picks up a Run." Pollers instantiate
Workflows or move Jobs through state; the dispatcher creates Runs, and
pollers do not call `RunJob.perform_later` directly. `ReapStaleRunsJob`
is a recovery sweep, not a normal dispatcher: it fails orphaned or stale
`running` Runs, re-enqueues queued successor Runs orphaned after inline
Step advancement, and lets terminal Workflow cleanup plus
`WorkflowWorkspacePruneJob` handle workspaces.

`Job` is the thread (one per GitHub issue, scheduled-task fire, or direct
operator prompt). `Workflow` is an attempt to move that Job forward.
`Step` is a stage in that attempt, and `Run` is one execution attempt for a
Step.

## Domain model

### Job — the *thread*

Lives in `app/models/job.rb`. One `Job` per GitHub issue, cron fire, or
direct operator prompt. Carries GitHub identifiers, ownership,
dependency/epic state, priority, selected agent provider, and lifecycle
state.

| Column | Meaning |
|---|---|
| `kind` | `"issue"` (created from a labeled issue), `"cron"` (created from a `ScheduledTask` fire), or `"direct"` (created from an operator prompt) |
| `state` | AASM lifecycle: triage/dependency states, execution states, approval/landing states, and `closed` |
| `repository_id`, `user_id`, `owner_user_id` | scope and durable assignee |
| `epic_id`, `epic_title` | optional Epic membership plus a denormalized title snapshot for dashboard/filter payloads; kept in sync when the Epic title changes |
| `issue_number` | nullable for cron and direct jobs |
| `issue_title`, `issue_body` | cached at ingest |
| `branch_name` | `syrus/issue-{N}-{job_id}` (issue Jobs), `syrus/scheduled-{task_id}-{job_id}` (cron Jobs), or a direct-job branch; assigned by workspace setup and persisted for follow-up Workflows |
| `pr_number` | the Syrus-opened PR, if any |
| `external_pr_number` | the *preempted* path — see below |
| `pr_mergeable`, `pr_mergeable_checked_at` | latest from GitHub; updated by `PollMergeStateJob` |
| `landing_failure_reason` | open landing failure explanation; set when auto-merge or merge-train landing cannot proceed and surfaced by dashboard attention filters |
| `failure_count` | consecutive non-rebase Run failures; reset on reopen; threshold `AppSetting.max_job_failures` auto-closes the thread with reason `too_many_failures` |
| `closure_reason` | string tag explaining why the thread closed (see table below) |
| `last_seen_comment_at`, `last_feedback_addressed_at` | PR-feedback watermarks; the poller uses the later timestamp so handled feedback is not re-enqueued |
| `last_ci_handled_sha` | watermark for CI-failure follow-ups |
| `scheduled_task_id` | nullable; set on cron Jobs |
| `priority` | `high` / `medium` / `low`, mapped to Solid Queue priorities 0 / 10 / 20 |
| `agent_provider` | provider captured for the Job; Workflows/Runs denormalize the selected provider |

Jobs also own optional operator metadata around the execution thread:
`job_tags`, `job_pins`, `documents` / `job_attachments`, and
`notifications`. Attachments are `Document` rows, so uploaded files,
Google Doc links, and issue/comment image captures all flow through the
same prompt-context path. Jobs also have optional `chat_proposals`
source links for work created from chat. `App::JobSourceChat` uses the
direct Job proposal when present, or falls back to the Epic proposal for
bundled child Jobs, so dashboard and Job detail payloads can link back
to the originating chat message.

`closure_reason` values:

| Value | Meaning |
|---|---|
| `nil` | Job is open |
| `cancelled` | operator cancelled active runs and closed the thread |
| `replaced` | operator clicked Restart, which closes-and-respawns |
| `replaced_by_scheduled_task` | a cron fire with `pr_pileup_policy=replace` superseded an earlier Job |
| `too_many_failures` | `failure_count` hit `AppSetting.max_job_failures` |
| `no_changes` | a cron Run finished with an empty diff and a one-line summary |
| `issue_closed` | the upstream labeled GitHub issue closed before Syrus opened a PR |
| `preempted` | the issue already had a human-opened PR when we ingested it |
| `pr_merged` | Syrus-opened PR merged |
| `pr_closed` | Syrus-opened PR was closed without merge and its branch still has unique patches |
| `external_pr_merged` | tracked preempting PR merged |
| `external_pr_closed` | tracked preempting PR closed without merge |
| `pr_approved` | operator accepted an approved PR as successful without auto-merge |

States and transitions:

```ruby
state :triaging, initial: true
state :blocked_by_epic, :queued, :running, :implemented, :failed
state :approved, :landing
state :closed

event :advance_after_triage
event :start_running
event :mark_implemented
event :mark_failed
event :retry_after_failure
event :approve / :unapprove
event :start_landing / :defer_landing / :fail_landing
event :close
event :reopen # clears closure_reason, finished_at, failure_count
```

### Epic — coordinated work

Epics group related Jobs under one repository and owner. They have their
own board lifecycle (`backlog`, `ready`, `in_progress`, `done`,
`archived`), dependency graph, ownership/claim fields, chat-proposal
source links, and optional merge-train landing behavior for approved
child Jobs. Starting an Epic unblocks its child Jobs; moving it back or
archiving it restores the child Epic block.

`EpicVersion` records title/description changes for audit and for
product-owner/developer handoff. Product owners can create and refine
backlog Epics, but developer/admin advancement is the gate that moves
them toward runnable child Jobs. Developer elaboration chat starts from
the preserved product-owner description and then materializes Jobs
through the normal proposal/dependency path.

### JobDependency and EpicDependency

`JobDependency` is the execution gate for Jobs. A row can target a
concrete `depends_on_job`, a concrete `depends_on_epic`, an unresolved
GitHub issue reference, or an unresolved `ChatProposal` from the same
operator's chat flow. Parsed issue-body dependencies set `source` to
`parsed`; operator/chat-authored edges set it to `manual`.

Pending references are first-class rather than lossy. A `Depends-on:
owner/repo#123` line can sit unresolved until the matching Job exists,
and a chat proposal can depend on another proposal card before either
card has been confirmed into a real Job. When the target materializes,
`JobDependency#resolve!` clears the unresolved fields and reruns the
cycle checks against the concrete Job. Same-Epic dependencies count as
satisfied once the upstream Job is `approved` or `landing`; other Job
dependencies require the normal successful closure states, and direct
Epic dependencies require the upstream Epic to be `done`.

Once resolved, the app treats the Syrus Job as the canonical dependency
target. Job detail banners and dependency panels link to the target
Syrus thread with a `JOB-<id>` slug; original GitHub issue numbers stay
as source/audit context, not as the primary dependency identifier.

`EpicDependency` models Epic-level gates. It can point at another Epic
or at a Job, prevents cycles, and refreshes the dependent Epic's
auto-state after commits. Job-to-Job dependencies that cross Epic
boundaries also materialize derived Epic dependencies, so Epic readiness
and merge-train behavior can see the higher-level ordering implied by
their child Jobs.

### Workflow, Step, Run — the *attempt machinery*

`Workflow` is the top-level attempt on a Job. `Step` rows materialize
the Workflow template. Each Step owns one or more Runs. A Run lives in
`app/models/run.rb` and carries the prompt, transcript metadata,
diff/head SHA, cost metadata, and provider-specific result for a single
Step execution.

| Column | Meaning |
|---|---|
| `state` | AASM (see diagram below) |
| `trigger_kind` | what the Workflow/Run is *for* (see table below) |
| `prompt` | the full prompt the agent sees |
| `agent_turns`, `agent_outcome`, `agent_diff`, `head_sha` | populated from the stream-json `result` event + post-run git capture |
| `agent_provider`, `cost_usd` | provider used for execution and captured provider cost |
| `agent_pr_title`, `agent_pr_body`, `agent_summary` | written by the agent via the MCP `submit_summary` tool |
| `parent_session_id` | prior session id used for supported same-workflow continuations such as summarize/amend and loop iterations |
| `last_heartbeat_at` | bumped on every `JobLog` write; used by `ReapStaleRunsJob` |

Workflows, Steps, and Runs use the same terminal-state shape:

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
| `initial` | `Job` create (issue Jobs auto-spawn the first Workflow after triage; cron Jobs do it via `PollScheduledTasksJob`) | makes the branch + opens the PR |
| `pr_comment` | `PollPullRequestJob` finds new review comments since `last_seen_comment_at` | reuses the same branch |
| `chat_feedback` | operator confirms feedback proposed from Syrus Chat | reuses the same branch; prompt source is the confirmed chat feedback artifact |
| `ci_failure` | `PollPullRequestJob` finds failing checks on the head SHA | reuses the same branch; gated on `last_ci_handled_sha` |
| `rebase` | `PollMergeStateJob` finds `pr.mergeable == false` and we control the head | rewrites history rather than commits; pushes with an explicit `--force-with-lease` lease |
| `stack_rebase` | dependent PR stack needs to be rebased branch-by-branch | force-pushes each updated branch and resumes landing |
| `auto_merge` | landing queue picked an approved Job | runs final gates, optional repair, push, and GitHub merge |
| `merge_train` | landing queue picked a ready Epic when merge train is enabled | builds and lands all approved child PRs atomically |
| `retry` | operator: "Run again" | new Run on the existing branch |
| `replay` | operator replay of a failed/retryable path | uses the retry Workflow template |
| `manual` | operator: explicit manual prompt | freeform |
| `resume` | operator continuation of a captured provider session | freeform prompt against retained session context |

State changes reach the browser through app events; see
[UI surface](#ui-surface) for how updates land in React.

### JobLog — the transcript

Append-only chunks per Run (`belongs_to :run`). `RunJob#log`, provider
invocations, the MCP sidecar, and `WorkflowWorkspace` all write to it.
Unique on `(run_id, sequence)`. `before_update` raises
`ReadOnlyRecord` — once written, never edited.

`broadcasts_to` per JobLog drives the live transcript on the job page.

### Repository

Unique on `(user_id, owner, name)`: the same GitHub repo can be
registered by multiple Syrus users, but not twice by the same user.
Per-user is the natural scope because Syrus uses either the linked
GitHub App installation or the user's PAT, plus the user's configured
agent credentials. Carries `default_branch`, `polling_enabled`,
`trigger_label` (default `"syrus"`), `archived_at`, `prepare_enabled`,
`trust_clean_rebase_grade`, and optional repository-level
`agent_provider`. Archive blocks polling even if `polling_enabled` is
true.

### User

Encrypted attributes include GitHub, Claude, and Codex credentials
(Active Record Encryption — `RAILS_MASTER_KEY` is required to read
them). `role` is either `developer` or `product_owner` and is serialized
into bootstrap/profile/admin-user payloads. Product-owner role limits
keep planning and backlog refinement separate from developer execution:
product owners can draft work and refine Epics, while developers/admins
advance Epics into runnable implementation. `agent_provider` is the
user's default for new Jobs; a
Repository can override it and per-Job retry/direct actions can choose
an explicitly configured provider. `agent_max_turns` is the per-user
ceiling on Claude `--max-turns`; `0` means "no `--max-turns` flag" —
the per-Run wall-clock timeout still applies. `theme` is a per-user UI
preference (`light` or `dark`) returned in the bootstrap payload and
updated through `PATCH /api/v1/app/theme`. `notification_preferences`
stores per-kind app notification toggles plus desktop-native toggles for
implemented/failed Job state alerts. Preferences are returned in
bootstrap/current-user payloads, updated through
`/api/v1/app/notification_preferences`, and the older credentials
payload still accepts desktop toggles for desktop settings
compatibility. `dashboard_preferences` stores subject-level
view/sort/column/lane choices plus `folder_prefs` slots keyed by active
smart folder id, so operators can keep different layouts and sort orders
for Inbox, Landing Queue, All Epics, and custom folders. The first user
to sign up is auto-promoted to admin (bootstrap convenience, not a core
architectural concern).

First-run setup is also user-scoped. `AppApi::SetupStatus` feeds the
React `/onboarding` route and root/navigation guards; `App::SetupStatus`
feeds older app payload surfaces that still expect setup summaries. The
current onboarding contract is: admin/account access, GitHub credentials
ready (PAT plus registered GitHub App), selected agent provider
configured, at least one active repository, onboarding chat started, and
then the first Epic landed. `User#first_run_setup_complete?` delegates to
`first_epic_landed?`, so setup is not complete merely because a Job
exists or a single PR succeeded; the first Epic has to reach `done`.
`User#onboarding_chat` is the durable chat session that unlocks the rest
of the app chrome and becomes the brand-link target until setup
finishes.

### ScheduledTask

Cron-style schedule (5-field expression, validated to fire at most
once per hour) or one-shot `fire_at`, attached to a Repository.
Periodically spawns a cron `Job` with a pre-rendered prompt
(`{{repo_slug}}`, `{{last_fired_at}}`, etc. expanded at fire time).
Cron tasks honor the entered minute exactly and are evaluated in UTC
hourly windows so repeated poller ticks do not double-fire the same
hour.

Scheduled tasks can optionally reference a `CronTemplate`. The
scheduled task stores its own prompt, cron expression, and pile-up
policy at creation time; the template is the reusable starting point
and audit link, not runtime indirection. Updating a template therefore
does not rewrite existing tasks, and deleting a template nulls the
reference on applied tasks.

The scheduled-task and cron-template forms surface the same cron
contract at the input: five fields, interpreted in UTC, with the minute
field honored and schedules limited to one fire per hour.

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
Unpause to re-enable.

### CronTemplate

Reusable per-user schedule template. A `CronTemplate` stores a name,
description, prompt, cron expression, enabled flag, and
`pr_pileup_policy`. It has many `ScheduledTask`s with
`dependent: :nullify`, which preserves already-applied scheduled tasks
if the template is later deleted.

The app API under `/api/v1/app/cron_templates` is user-scoped: users can
list, create, edit, delete, and view applied tasks for their own
templates. The "apply" flow links from a template to a repository's new
scheduled-task form with `from_template=<id>`, where the scheduled task
form copies the template values into a concrete repository-owned task.

Cron expression validation mirrors `ScheduledTask`: Fugit parses the
five-field expression and rejects schedules that can fire more than once
per hour.

### ClaudeSession and provider sessions

One row per Run that captures a provider session, holding the provider,
`session_id`, transcript JSONL, and enough metadata for supported
same-workflow continuations. Claude sessions can resume with
`claude --resume <session_id>`; Codex continuations replay retained
transcript JSONL through `CodexInvocation`. Retained for **14 days after
the parent Run reaches a terminal state**
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
| `LandingQueueProcessorJob` | every 30 sec | Picks approved Jobs/Epics for landing workflows |
| `PollScheduledTasksJob` | every 1 min | Finds due `ScheduledTask`s; fires via `ScheduledTaskFire` |
| `ReapStaleRunsJob` | every 1 min | Recovers RunJob crashes: fails orphaned/stale `running` Runs, re-enqueues orphaned `queued` Runs, and finishes terminal Workflows |
| `DataRootDiskUsageRefreshJob` | every 1 min | Refreshes `$SYRUS_DATA_ROOT` disk usage for operator visibility |
| `ReapClassifierPendingJob` | every 5 min | Re-enqueues classifier work for Jobs stuck in classifier-pending triage |
| `ReapOrphanedSpawnedProcessesJob` | every 1 min | Finalizes subprocess rows owned by dead hosts |
| `ReapStaleInstanceVersionsJob` | every 1 min | Finalizes stale web/worker instance rows |
| `SpawnedProcessPruneJob` | daily 3:20am | Deletes old finished subprocess rows |
| `ClaudeSessionPruneJob` | daily 3:00am | Deletes expired retained provider sessions |
| `RunDiagnosticPruneJob` | daily 3:10am | Deletes old run diagnostics |
| `PruneOldNotificationsJob` | daily 3:30am | Deletes app notifications older than 30 days |
| `WorkflowWorkspacePruneJob` | every 2 hours | Removes old terminal Workflow workspaces |
| `SyncAgentSkillsJob` | every hour | Synchronizes agent skill metadata |
| `SyncInstallationsJob` | every 5 min | Refreshes GitHub App installation links |
| `ReconcileJobStatesJob` | every 5 min | Repairs drift between Job state and terminal evidence |
Plus one Solid Queue housekeeping entry, `clear_solid_queue_finished_jobs`,
which is production-only because dev wipes the Solid Queue tables
often enough on its own. It runs hourly and `delete_all`s finished
job rows in batches.

## Per-poller flow

### Repository ingestion (issue → Job → Run)

```
PollRepositoryJob (per repo, serialized via SolidQueue concurrency key)
  → GithubClient.for(repository:, user:).issues_with_label(slug, trigger_label)
  → close open issue Jobs with no PR when their upstream issue is now closed
  → IngestPolicy filters (skip closed issues, PRs, syrus-skip label)
  → For each surviving issue:
      latest Job for repository + issue_number dedups active work
      classifier/dependency/epic gates run
      issue markdown images are ingested as Job attachments
      if ready:
        Workflows::Initial.instantiate(job:)
        StepDispatcher.start_workflow(workflow)
          first Step's Run is created
          Run#after_create_commit → enqueue_run_job
            RunJob.perform_later(run_id) hits SolidQueue
```

The initial Workflow autostarts for issue-kind Jobs only once triage,
Epic gating, and dependencies release the Job. Cron-kind Jobs have their
initial Workflow/Run created explicitly by `PollScheduledTasksJob` with
a pre-rendered prompt (so `{{date}}` and friends reflect fire time, not
RunJob start time). Direct Jobs are operator-created free-form prompts
and use the same Workflow machinery.

Dedup is intentionally "latest Job for this repository + issue" rather
than "any historical Job": an existing open thread absorbs label and
external-PR discoveries, while a fully closed thread can be followed by
a new active thread for the same upstream issue.

### PR and chat feedback (`pr_comment`, `chat_feedback`, `ci_failure`)

```
PollAllPullRequestsJob
  → PollPullRequestJob per open Job with pr_number
      → fetch issue comments, review comments, reviews, checks
      → filter to events newer than max(last_seen_comment_at,
        last_feedback_addressed_at)
      → if any new comment exists:
          Workflows::PrFeedback.instantiate(...)
          StepDispatcher.start_workflow(...)
      → if checks on pr.head.sha are failing AND sha != last_ci_handled_sha:
          Workflows::CiFailure.instantiate(...)
          StepDispatcher.start_workflow(...)
      → bump last_seen_comment_at / last_ci_handled_sha as watermarks
```

Chat feedback is not poller-created. In a repository-scoped chat, the
agent can call `submit_chat_feedback` only after discussing the requested
change with the operator and checking that no `chat_feedback` Workflow is
already active for the Job. The tool creates a `ChatPendingAction`; when
the operator confirms it, `ChatPendingAction#apply!` instantiates
`Workflows::ChatFeedback` with a `chat_feedback` artifact and starts the
Workflow. The Job must be `implemented` or `approved`; confirming
feedback on an approved Job unapproves it so the landing queue does not
merge stale work.

Chat proposals share the same dependency model before and after
confirmation. `propose_job` can depend on existing Jobs, existing Epics,
or other Job proposal slugs from the chat session. `propose_epic_with_jobs`
can chain sibling child Jobs, point child Jobs at existing Epics, and
point the Epic itself at existing Jobs, existing Epics (`epic:<id>`), or
other Epic proposal slugs. Confirming an Epic-with-Jobs card runs one
transaction that topologically creates the Epic and child Jobs, wires
sibling and cross-card Job dependencies, rewrites resolved Epic proposal
tokens to stable `epic:<id>` tokens, and resolves any pending
proposal-backed dependency rows. Jobs are advanced after triage only once
those gates are in place.

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
      → bail if a runnable rebase/stack-rebase Workflow is already active
      → bail if rebase attempt cap reached
      → Workflows::Rebase.instantiate(...)
      → auto_rebase Step tries deterministic `git rebase`
          clean? cancel only agent_rebase, continue to force_push
          conflict? leave in-progress rebase for agent_rebase
```

The fast path is now a Step inside the Workflow instead of an in-poller
shortcut. Most rebases still avoid the agent: `auto_rebase` succeeds,
`agent_rebase` is cancelled, and `force_push` updates the PR branch.
Only conflicts that require judgment escalate to the agentic
`agent_rebase` Step.

`RebaseWorkflowSelector` is the shared gate for rebase vs. stack-rebase
selection and for "already active" checks. Its active scope deliberately
ignores stale active Workflow rows that never created a Run, so old
no-run rebase attempts do not block future merge-state polling or manual
rebase commands. If `StepDispatcher.start_workflow` later discovers that
dependencies or stack readiness make a newly-created rebase Workflow
unstartable, it cancels that Workflow and records
`start_blocked_reason` in artifacts instead of leaving an active
Workflow with no Run.

### Scheduled tasks

```
PollScheduledTasksJob (every minute)
  → alive ScheduledTasks for active repositories and unpaused users
      whose scheduled fire time has arrived
      → ScheduledTaskFire.call(task)
        → render prompt (variable expansion: {{date}}, etc.)
        → apply pr_pileup_policy if a prior cron-Job's PR is still open
        → Job.create!(kind: "cron", scheduled_task_id: task.id, ...)
        → Workflows::Initial.instantiate(...)
        → first Run created with prompt: rendered
        → bump last_fired_at, last_successful_fire_at, etc.
```

Cron expressions are interpreted in UTC. Five-field cron schedules must
fire at most once per hour, but Syrus honors the entered minute exactly
and records the evaluated window so repeated poller ticks do not double
fire the same hour.

### Stale Run reaping

```
ReapStaleRunsJob (every minute)
  → Solid Queue RunJobs failed by ProcessPrunedError
      → expand root Run ids to any inline running Runs in the same Workflow
      → mark as failed (agent_outcome: "worker_died")
  → running Runs with no active SolidQueue::Job after a grace period
      → mark as failed (agent_outcome: "worker_died")
  → running Runs with stale last_heartbeat_at
      → mark as failed (agent_outcome: "worker_died")
  → queued Runs with no active RunJob driving their Workflow
      → re-enqueue (the successor was created for inline execution but the worker died)
  → terminal Workflows left active by a crash
      → finish the Workflow and let terminal cleanup handle the workspace
```

The 30-minute heartbeat threshold is the backstop, not the only signal.
The faster paths use Solid Queue evidence: a `ProcessPrunedError` means
the worker process is gone, and a `running` Run with no active RunJob
after the grace period has no worker that can resume it. The queued-Run
path exists because `RunJob` drives a Workflow chain inline: after one
Step succeeds, the next Step's Run is created in `queued` state and is
normally picked up by the same worker without a new queue row. If that
worker dies in the gap, the recovery action is to enqueue the side-
effect-free queued Run, not fail it. The heartbeat is bumped on every
`JobLog#log` write — not on a separate timer — so "agent producing
transcript output" implicitly counts as alive.

## Per-Workflow pipeline

Workflow definitions live in `app/services/workflows/` and Step
handlers live in `app/services/steps/`. `Workflows::Base` materializes a
chain of Step rows and stores the serialized chain template; `Step` rows
are wired with `next_step_id`, and `StepDispatcher` creates exactly one
Run for each Step as the chain advances. Control nodes such as
`Workflows::RetryUntil` append bounded repair/check iterations when a
grader-collect step fails.

Current Workflow chains:

| Trigger | Chain |
|---|---|
| `initial` | `prepare → optional loop(implement → adversarial_review) → retry_until(implement → grader_fanout → grader_collect) → summarize → test_plan → pr_open` |
| `pr_comment` | `prepare → retry_until(respond → grader_fanout → grader_collect) → summarize_amend → push` |
| `chat_feedback` | `prepare → retry_until(respond → grader_fanout → grader_collect) → summarize_amend → push` |
| `ci_failure` | `prepare → analyze_and_fix → summarize_amend → push` |
| `retry` / `replay` | same shape as `initial`, reusing the existing branch and PR if present |
| `manual` / `resume` | `manual` |
| `rebase` | `auto_rebase → agent_rebase → force_push` |
| `stack_rebase` | `stack_auto_rebase → stack_agent_rebase → stack_force_push` |
| `auto_merge` | `mergeability_preflight → prepare → retry_until(grader_fanout → grader_collect, repair: landing_fix) → push → auto_merge` |
| `merge_train` | `merge_train_assemble → merge_train_build → prepare → retry_until(grader_fanout → grader_collect, repair: landing_fix) → merge_train_land` |

`prepare` reads `.syrus.yml` or auto-detects setup commands from
lockfiles. Explicit `.syrus.yml` commands are operator intent and
hard-fail the Step on error; auto-detected commands are guesses and
soft-fail with a recorded `prepare_failure` artifact so the agent still
runs and can fix setup from inside the repository. It can be disabled
per repository or skipped for one Job with the `syrus-skip-prepare`
label; the skip is recorded in Workflow artifacts and logged on the
first Run.

Agentic Steps (`implement`, `adversarial_review`, `respond`,
`analyze_and_fix`, rebase repair, landing repair, summarize, test_plan,
and manual) invoke the Workflow's
configured provider through `AgentProviders::*`. Non-agentic Steps run
service code: graders, git push/force-push, PR opening, mergeability
gates, merge API calls, and merge-train assembly/landing.

The optional `adversarial_review` loop applies only to Initial
Workflows. `RepoAdversarialReviewPlan` reads repository configuration
from `.syrus.yml` and falls back to `AppSetting.adversarial_review_rounds`
when appropriate. Each loop iteration runs implementation, then an
independent reviewer prompt over the succeeded diff; the reviewer must
call `submit_adversarial_review` with `approved` or `needs_work`.
The verdict is recorded for audit/future control; today
`StepDispatcher` runs the configured number of review rounds and feeds
prior findings into each next implementation iteration before advancing.

`respond` is shared by `pr_comment` and `chat_feedback` Workflows. The
PR-comment path composes `Prompts::PrFeedback` from GitHub comments,
cutoffs, and prior summaries; the chat-feedback path composes
`Prompts::ChatFeedback` from the confirmed `chat_feedback` artifact,
prior feedback summaries, recent branch commits, and optional Epic
context. Both commit to the existing branch and hand revision copy to
`summarize_amend` before `push`.

`RunJob#perform` is now the per-Step executor:

1. Find the Run, Step, Workflow, and Job; bail if the Run is terminal.
2. Enforce the Job-closed guard except for maintenance workflows that
   intentionally operate on preempted/external PRs.
3. Start the Workflow/Step/Run AASM states and record timestamps.
4. Ensure the shared `WorkflowWorkspace` exists at
   `$SYRUS_DATA_ROOT/workflows/<workflow_id>/`, with the default branch
   available for three-dot diffs and the correct work branch checked out.
5. Dispatch to `Step::Kind.handler_for(step.kind)`.
6. Persist Run metadata: provider result, turns, session capture, cost,
   diff/head SHA where relevant, and failure diagnostics.
7. On Step success, `StepDispatcher.advance_from` creates the next Run
   or marks the Workflow succeeded. On failure, graders aggregate and may
   trigger another retry iteration; ordinary failures fail the Workflow.

Terminal Workflow transitions own workspace lifecycle. `commit_agent_changes`
is called by file-editing agentic handlers before downstream diff/push
steps. Diff capture uses `git diff <default_branch>...HEAD` so PR views
match GitHub's "Files changed" tab.

### Cleanup and error handling

- Terminal Workflow transitions clean up or retain the shared workspace
  according to state; `WorkflowWorkspacePruneJob` removes old terminal
  workspaces.
- On exception: AASM `fail!`; record `agent_outcome`; `Job#record_run_failure!`
  for non-rebase Runs (rebase failures don't bump `failure_count`).
- On SIGTERM: Solid Queue's graceful-shutdown timeout lets the current
  Run finish if it can. If the worker is killed mid-flight (K8s deploys,
  OOM), `ReapStaleRunsJob` uses Solid Queue prune evidence, orphaned
  Run detection, and the heartbeat backstop to either fail the abandoned
  `running` Run or re-enqueue an abandoned `queued` successor Run.

## End-to-end GitHub workflow

What happens to a single labeled issue, from label to merge:

1. **Label applied** on a registered repo's issue (default label
   `syrus`).
2. **Within 5 min**, `PollRepositoryJob` for that repo finds the issue.
   `IngestPolicy` lets it through (open, not a PR, no `syrus-skip`
   label, no existing active `Job`). A `Job(kind: issue)` is created
   and triage/dependency/Epic gates decide when it can run.
3. **Triage completes.** `ClassifyIssueJob` (or an explicit direct/cron
   creation path) calls `advance_after_triage!`; that transition invokes
   `create_initial_run_if_needed`, instantiates the initial Workflow, and
   `StepDispatcher.start_workflow` creates the first `Run(trigger_kind:
   initial, state: queued)` once the Job is executable.
4. **`Run#after_create_commit`** enqueues `RunJob.perform_later(run.id)`.
5. **A worker picks up the RunJob**:
   - Sets up the worktree on a fresh branch `syrus/issue-{N}-{job_id}`.
   - Composes the initial prompt from the issue title + body via
     `Prompts::Initial`.
   - Invokes the selected provider (Claude Code or Codex) with the MCP
     sidecar attached.
   - Agent works in the `implement` Step: edits files and commits.
   - If adversarial review is configured, an independent
     `adversarial_review` Step critiques the diff before the normal
     grade loop and can request another implementation round.
   - Grader Steps run configured `.syrus.yml` checks; failures append
     another bounded repair/check iteration.
   - The `summarize` Step asks the agent to call `submit_summary`
     unless the implement Step already provided PR copy.
   - The `test_plan` Step asks the agent to call `submit_test_plan`
     with reviewer-facing checks; `pr_open` appends them to the PR body.
   - `pr_open` pushes the branch and opens the PR (using Workflow
     artifacts first, then `PrSummarizer`, then templated copy).
   - Workflow transitions to `succeeded`; Job moves to `implemented`.
6. **PR is now open**. From this point:
   - `PollPullRequestJob` watches every 5 min for new review comments
     on this Job. New comment → `pr_comment` follow-up Run on the
     same branch.
   - Syrus Chat can propose operator-agreed feedback on an implemented
     or approved Job. Operator confirmation → `chat_feedback` follow-up
     Run on the same branch.
   - `PollPullRequestJob` watches CI checks. Failing check on the
     head SHA → `ci_failure` follow-up Run on the same branch.
   - `PollMergeStateJob` watches mergeability. Unmergeable + we
     control the head → a `rebase` Workflow re-anchors the branch.
   - GitHub approvals can mark the Job `approved`; the landing queue
     creates an `auto_merge` Workflow, or a `merge_train` Workflow for
     ready Epics when merge trains are enabled.
7. **PR, issue, or branch work is otherwise finalized.** Syrus closes
   the Job with a terminal `closure_reason` such as `pr_merged`,
   `pr_closed`, `external_pr_merged`, `external_pr_closed`,
   `pr_approved`, `issue_closed`, or `no_changes`. When a Syrus-opened
   PR is closed without merge,
   `ClosedPullRequestResolution` checks whether the branch patch is
   already present on the base branch with `git cherry`: patch-equivalent
   closures become `no_changes`, while closures with still-unique
   patches become `pr_closed`.

## Services

Core (the agent loop):

| Service | Purpose |
|---|---|
| `WorkflowWorkspace` | Fresh per-Workflow clone at `$SYRUS_DATA_ROOT/workflows/<workflow_id>/`. Default root `~/.syrus` (override with `SYRUS_DATA_ROOT`). Clones never live inside `Rails.root` — protects the operator's checkout from agent chdir mishaps. |
| `ChatWorkspace` | Persistent per-chat workspace under `$SYRUS_DATA_ROOT/chat-workspaces/<chat_session_id>/`. Repositories are cloned lazily for inspection and fast-forwarded between turns; implementation still belongs to Workflow workspaces. |
| `AgentProviders::*` | Provider abstraction for Claude and Codex. Selects credentials, prepares provider home/session state, wires MCP, invokes the provider-specific runner, captures transcript/session metadata, and returns a normalized result. |
| `ClaudeInvocation` / `CodexInvocation` | Subprocess adapters that parse provider output, thread chunks into `JobLog`, capture final result metadata, and enforce the wall-clock timeout. |
| `SyrusMcp::Sidecar` | MCP server the agent talks to over stdio. Exposes `read_live_state`, `submit_summary`, `submit_test_plan`, and `submit_adversarial_review`. See [MCP sidecar](#mcp-sidecar). |
| `SyrusChatMcp::Sidecar` | MCP server for chat turns. Exposes repository/job/PR inspection, proposal, scheduling, bookmark, note, and whiteboard tools scoped to the active `ChatSession`. See [Chat sidecar and workspaces](#chat-sidecar-and-workspaces). |
| `Prompts::*` | One class per prompt surface: `Initial`, `AdversarialReview`, `PrFeedback`, `ChatFeedback`, `CiFailure`, `Rebase`, `ScheduledTask`, `DirectJob`, `TestPlan`, plus `EpicContext` mixed into Epic-owned Job prompts, `PullRequestSummary` for `PrSummarizer`, and `SubmitSummaryInstructions` mixed into prompts that should expose the MCP tool. |

Git and GitHub:

| Service | Purpose |
|---|---|
| `GitRunner` | Subprocess wrapper around `git` that streams stdout/stderr into `JobLog` and redacts `https://x-access-token:TOKEN@github.com/...` URLs from error messages. |
| `GithubClient` | One Octokit client per user. Wraps `issues_with_label`, `pull_request`, `pull_request_comments`, `pull_request_reviews`, `combined_status_for_ref`, etc. Surfaces `Octokit::TooManyRequests` to callers (logged then re-raised). |
| `PullRequestOpener` | Octokit `create_pull_request` with retry on transient failures. |
| `LandingQueueProcessor` | Orders the approved/landing queue, groups Epic children as one landing unit for queue display and merge-train dispatch, exposes dependency and unapproved-sibling blockers for each unit, moves eligible Jobs/Epics into `auto_merge` or `merge_train` Workflows, and applies landing state transitions. |
| `LandingValidationCache` | Records prior green landing checks; optionally lets clean rebases carry validation forward for repositories that trust it. |
| `ClosedPullRequestResolution` / `BranchPatchPresence` | Classifies closed Syrus PRs as merged, no-change, or closed-with-unique-patches. The patch-presence check clones the base branch under `$SYRUS_DATA_ROOT/closed-pr-checks`, fetches the Syrus branch, and uses `git cherry` to detect whether any patch remains unique to the PR branch. |

Policy and pipeline glue:

| Service | Purpose |
|---|---|
| `IngestPolicy` | The "should we make a Job for this issue?" filter — skips PRs, closed issues, the `syrus-skip` label, etc. |
| `IssueImageExtractor` / `IngestIssueImagesJob` / `JobImageAttachmentIngestor` | Pull image URLs from GitHub issue and PR feedback markdown, download supported images with GitHub credentials when needed, and store them as Job `Document` attachments so later agent prompts can inspect them from the workspace. |
| `PrSummarizer` | Second-shot provider call that takes issue + diff and returns `{title, body}` JSON. Tier 2 fallback when the agent didn't call `submit_summary`. |
| `ScheduledTaskFire` | Encapsulates the "fire a due ScheduledTask" decision: pile-up policy, prompt rendering, Job + Run creation, watermark bumping. |
| `ProviderCircuitBreaker` / `AutoRetryScheduler` | Suppress automatic work during provider-wide outages and retry transient failures with bounded backoff. |

### Rebase and landing

Most rebases are mechanical: PR was opened, base branch moved, no
overlapping edits. The rebase Workflow keeps that path cheap by trying
`auto_rebase` before invoking the agent.

`auto_rebase` checks out the PR's branch in the Workflow workspace, runs
`git rebase origin/<base>` non-interactively, and:

- **Clean rebase** → pushes the rebased branch with an explicit
  `--force-with-lease` lease in the later `force_push` Step. The
  agentic Step is cancelled.
- **Conflict** → leaves the in-progress rebase for `agent_rebase`,
  which resolves conflicts and runs `git rebase --continue` until the
  same rebase finishes. `force_push` then updates the branch with the
  observed lease.

Landing is also a Workflow, not an inline merge button. `auto_merge`
starts with `mergeability_preflight`, runs final graders on the exact
branch about to land, optionally invokes `landing_fix`, pushes repairs,
and then calls GitHub's merge API. Epic merge-train landing builds a
single integration branch from approved child PRs by fetching each
member branch with repository credentials (private repos included),
validates it, merges one integration PR, and comments on/closes member
PRs as an all-or-nothing unit.

The landing queue is ordered by landing units, not only individual Jobs.
Epic children share one unit so the dashboard queue keeps the sibling
Jobs contiguous and the visible positions match the order Syrus uses
when dispatching merge-trains. Dependencies and `parent_job` edges are
still honored: the processor topologically orders units against
cross-unit prerequisites, then orders Jobs inside each unit by the same
dependency rules before landing or assembling the integration branch.
Each landing unit also carries the Jobs currently blocking it for
dashboard explanation. Those blockers include transitive explicit
dependencies and, for an Epic unit, same-Epic sibling Jobs that are not
yet approved or closed even when there is no explicit dependency edge.

## MCP sidecar

Provider adapters construct a `SyrusMcp::Sidecar` per Run and point the
agent at it over stdio. Today's tool surface:

- `read_live_state(detail:)` — read-only snapshot of the current Job,
  Workflow, Run, queue, and related chat state; agents use it before
  making operational claims. In chat contexts this related state can
  include attached sessions, pending chat action counts, turn-in-flight
  status, stop requests, and recent message snippets.
- `submit_summary(pr_title:, pr_body:, summary:)` — records
  agent-authored PR copy on Workflow artifacts and appends an audit
  `JobLog` line. Read tier-1 by `pr_open`/`push`/summary promotion
  paths.
- `submit_test_plan(steps:, notes:)` — records reviewer-facing manual
  test steps on Workflow artifacts and appends an audit `JobLog` line.
  `pr_open` reads this artifact and adds a Test Plan section to initial
  PR bodies, headed by a copy-pasteable `syrus checkout JOB-<id>` command.
- `submit_adversarial_review(critique:, verdict:)` — records one
  adversarial review iteration on Workflow artifacts. The
  `adversarial_review` Step requires this tool call; the stored
  critique is fed into later review-loop iterations, while the verdict
  is retained for audit/future control.

The sidecar lives in-process with Rails, so tool handlers are plain
ActiveRecord calls scoped to the active Run. No network, no auth
plumbing.

`bin/syrus-mcp-sidecar` is the binstub providers spawn; it boots Rails
and hands stdio to `SyrusMcp::Sidecar`. For Claude, the MCP config key
must match the binary basename (`syrus-mcp-sidecar`) so resumed sessions
keep the same tool prefix. SIGTERM is trapped to drain cleanly.

## Chat sidecar and workspaces

Top-level chat is separate from Workflow execution. A `ChatTurnJob`
runs on the dedicated `chat` queue, serialized per `ChatSession`, and
invokes Claude in a persistent `ChatWorkspace`. That workspace lives at
`$SYRUS_DATA_ROOT/chat-workspaces/<chat_session_id>/`, survives across
turns, and is pruned after idle retention by
`WorkflowWorkspacePruneJob`. Repository attachments are cloned lazily
under `repositories/<owner>/<name>` with depth 50 and fast-forwarded to
the repository default branch on reuse. Chat agents are configured with
write/edit tools disabled; they inspect code, maintain notes and
whiteboard state, and propose or queue work rather than editing a
repository checkout directly.

Each chat turn writes a temporary MCP config for `bin/syrus-chat-sidecar`
with `SYRUS_CHAT_SESSION_ID` in the environment and `alwaysLoad: true`.
`SyrusChatMcp::Sidecar` boots Rails over stdio and scopes every tool to
that chat session. Its tools cover:

- Repository context: attach repositories, read repo metadata and notes,
  list/read attached documents, list Jobs/issues/PRs, and read Job,
  Epic, or PR details.
- Operator actions: propose GitHub issues, Syrus Jobs, Epics, or an
  Epic with child Jobs; delete proposals; schedule recurring work;
  schedule/list/cancel one-shot chat wakeups; update Job
  title/description copy; and submit chat feedback, retry, rebase, or
  cancel Jobs visible to the session.
- Collaboration state: ask blocking operator questions, set bookmarks,
  read/search/manage chat memories, and mutate the chat whiteboard
  through scene/drawing tools.
- Admin diagnostics and controls, for admin users only: overview,
  stuck-item, queue, process, run, user, and version reads plus
  confirmed actions such as killing a subprocess, pausing/unpausing
  polling or runs, pausing user scheduling, retrying failed Steps,
  cleaning workspaces, clearing GitHub cache, and refreshing
  installations.

Most chat actions stop at a confirmation boundary. `ChatPendingAction`
stores these proposed mutations, with `pending` actions shown to the
operator for confirm/reject and `queued` actions held until their target
Job reaches an actionable state. For `submit_chat_feedback`, the MCP
tool creates the pending action after the agent and operator agree on
feedback; feedback for queued/running Jobs is stored as `queued` and
promoted when the Job is implemented or approved. Confirming it queues a
`chat_feedback` Workflow and stores the feedback text in Workflow
artifacts; rejecting or cancelling it leaves the Job untouched.

One-shot chat wakeups are `ChatWakeup` rows owned by the chat session
and user. `schedule_wakeup` creates a pending wakeup and enqueues
`ChatWakeupFireJob` for `fire_at`; `list_wakeups` and `cancel_wakeup`
operate only on pending wakeups for the current session. When the fire
job runs, `ChatSession::WakeupTurn` appends a user-role message tagged
with `requested_by: "wakeup"` and the wakeup id, marks the wakeup fired,
and enqueues `ChatTurnJob` so the follow-up stays in the same
transcript.

Small metadata edits that do not schedule work, such as `update_job`,
apply immediately after repository-scoped authorization. The tool can
change `issue_title`, `issue_body`, or both for a Job visible to the
chat's repository, and returns the updated copy plus the Job state.

Onboarding chat uses the same chat substrate with an `onboarding: true`
session and extra `Prompts::ChatOnboarding` guidance. The final setup
step is intentionally chat-led: the agent proposes an Epic and child Jobs
as normal `ChatProposal` rows, the operator confirms the proposal card,
and materialization creates the Epic/Jobs without starting the Epic
automatically. A confirmed Epic proposal whose materialized Epic is still
`backlog` or `ready` renders a small **Start** action in chat; clicking it
calls the Epic state API to move the Epic to `in_progress`, which is the
point where its child Jobs become runnable.

Role-aware chat guidance keeps product-owner and developer work
separate. Product-owner chats can shape backlog Epics and preserve
their vision in Epic version history; developer chats on those Epics
switch into elaboration mode, pull the original description into the
agent environment snapshot, and produce the implementation-ready child
Jobs.

`ChatTurnJob` persists assistant text, tool calls, tool results, and MCP
health events as `ChatMessage` rows, updates cumulative token/cost
fields on the `ChatSession`, and retains the provider session for
resumed turns. If a user sends another message while the turn is busy,
the controller stores a `ChatQueuedMessage`; when the active turn
finishes, `ChatTurnJob` atomically delivers the next queued message and
enqueues the following turn. Ctrl+C from the CLI and the UI Stop control
both set `stop_requested_at`, which the running Claude invocation polls
and records as a cancelled chat turn; each turn clears stale stop
requests as it exits so the next turn is not cancelled by an old signal.
Chat index records and app events carry `turn_in_flight`/`agent_busy`
state, letting the React sidebar mark active chat turns without waiting
for a full recent-chat refetch.

## Failure recovery

Several layers, each catching different failure modes:

1. **Provider timeout** — 30-minute wall-clock cap (and Claude
   `--max-turns` for users with `agent_max_turns > 0`). The provider
   adapter kills the subprocess and returns a timed-out result; `RunJob`
   calls `fail!`.
2. **Workflow terminal cleanup** — terminal transitions clean up or retain
   the shared workspace according to state. Cleanup failures are logged but
   don't suppress the original exception.
3. **Run reaper** — `ReapStaleRunsJob` runs every minute and combines
   Solid Queue state with Run state. It fails `running` Runs whose
   RunJob was pruned with `ProcessPrunedError`, `running` Runs that have
   no active RunJob after the grace period, and `running` Runs whose
   heartbeat is older than 30 min. It also re-enqueues orphaned
   `queued` successor Runs that were created for inline execution before
   their worker died, and finishes terminal Workflows left active by a
   crash.
4. **Re-entrancy guard** — distinct from the terminal-state bailout.
   On entry, `RunJob#perform` first bails silently if the Run is
   already `terminal?` (idempotent retry). Only if the Run is
   already in `running` state — which only happens when the prior
   worker crashed — does it call `fail!` and skip execution.
5. **Failure classification + auto-retry** — failed Runs persist a
   `RunFailureClassification` from diagnostics, logs, spawned process
   outcomes, and agent outcome. `AutoRetryScheduler` can retry
   transient failures with bounded backoff, unless
   `ProviderCircuitBreaker` has opened for that provider.
6. **Subprocess inventory** — `ProcessRunner` registers agent, grader,
   git, and prepare subprocesses as `SpawnedProcess` rows with
   heartbeats, host metrics, and a cross-pod kill switch. An in-process
   supervisor catches local dead pids; `ReapOrphanedSpawnedProcessesJob`
   catches dead worker hosts.
7. **`failure_count` and auto-close** — `Job#record_run_failure!` is
   called by `RunJob` after a non-rebase Run fails. It increments
   `failure_count`; if the result hits `AppSetting.max_job_failures`,
   the Job auto-closes with `closure_reason="too_many_failures"`.
   Reopening a Job resets the counter. **Rebase Run failures don't
   count** — they're independent of the issue's progress and a
   transient base-branch tangle shouldn't burn through the failure
   budget. Rebase and stack-rebase workflows have their own caps.

## UI surface (what shows up where)

- **`/onboarding`** — first-run setup checklist. The route opens guided
  modals for GitHub credentials (PAT first, then GitHub App
  registration/installation), agent credentials, and the first repository,
  then starts the onboarding chat that creates and lands the first Epic.
  `/setup` is retired and redirects here.
- **`/`** and **`/dashboard/*`** — dashboard: Epic, Job, and Workflow
  list/Kanban views with ownership scopes, smart folders, status pills,
  bulk actions, search filters, and landing controls.
- **`/repositories`** — registry: add/remove, archive, toggle
  polling, per-repo trigger label, prepare/trust-rebase settings,
  agent provider, manual poll, scheduled tasks.
- **`/repositories/:id`** — show page: metadata, recent jobs,
  GitHub link, retry failed Jobs with alternate providers.
- **`/jobs/:id`** — the operational hub for a single thread:
  live-streaming transcript per Run, agent diff, PR + branch links,
  action buttons (`run_again`, `restart`, `cancel`, `reopen`,
  `poll_feedback`, `rebase`, `check_mergeability`, `stop_run`,
  approval/landing actions, claim/release, dependencies, tags). Job
  detail payloads include `source_chat` links back to the chat proposal
  that created the Job (or the Epic proposal for bundled child Jobs) and
  `scheduled_task` links back to the recurring task that created a cron
  Job. The Summary tab renders feedback history from `pr_comment` and
  `chat_feedback` Workflows.
- **`/scheduled_tasks`** — cron task management.
- **`/cron_templates`** — reusable schedule templates and links to apply
  them to repositories.
- **`/jobs/new`** — operator-created free-form Jobs.
- **`/chats`** — top-level chat sessions, proposal review,
  attached repository/document context, bookmarks, whiteboard state, MCP
  health, and queued follow-up messages.
- **`/terminal`** — labs terminal surface, gated by the `terminal`
  feature flag. Sessions can attach to a recent Workflow workspace or a
  scratch directory and are backed by worker-side PTYs, not browser-side
  shells.
- **`/notifications`** and **`/notifications/settings`** — app
  notification inbox and per-kind preferences. The API returns unread
  counts, Job ids/titles, PR URLs, and read state; web and desktop
  clients mark rows read through the app API. Mark-read and
  mark-all-read actions broadcast compact `notification_read` app events
  so every open client updates read state and unread counts without
  waiting for the next full notification refetch. Settings include both
  app notification kinds (`job_failed`, `job_implemented`,
  `pr_comment_addressed`, `pr_merged`, `epic_completed`) and
  desktop-native alert toggles for implemented/failed Jobs.
- **`/insights/spending`** — Run and chat spend by window, Epic, user,
  repository, trigger kind, provider, trend, and top Runs.
- **`/credentials/edit`** — GitHub, Claude, Codex, scheduling pause, and
  default provider settings.
- **Theme toggle** — rendered in the React app shell for authenticated
  users. It optimistically flips the `dark` class on `<html>`, persists
  `User#theme` through `/api/v1/app/theme`, and re-syncs from the
  bootstrap/current-user payload.
- **Feature flags** — declared in `config/features.yml`, synchronized
  into `Feature` rows, serialized through the bootstrap
  `feature_flags` payload, and toggled by admins at `/admin/features`.
  `v2_sidebar_subject_selector` controls the dashboard subject selector
  inside the V2 sidebar.
- **`/settings/edit`** — admin settings toggles (signups open, max job
  failures, merge-train enablement, etc.); redirects non-admins to
  credentials.
- **`/settings`**, **`/profile`**, **`/settings/agent`**, and
  **`/settings/preferences`** — account profile, credentials, agent
  defaults, and per-user preferences.
- **`/invitations`** — admin invite flow.
- **`/admin/queue`** — admin Solid Queue view for active, pending,
  failed, recurring, and worker tabs. Queue filters support built-in and
  user-saved smart folders scoped to the queue surface; invalid filter
  expressions return structured `invalid_filter` errors instead of
  crashing the page.
- **`/admin/processes`** — subprocess inventory with host metrics and
  kill controls.
- **`/api/v1/admin/*`** — bearer-token admin API for overview, jobs,
  workflows, runs, queues, processes, and version/instance status.

During first-run setup, React uses bootstrap setup payloads to gate app
chrome. Before the onboarding chat
starts, root/dashboard visits are redirected to `/onboarding`, the only
top-level navigation item is **Setup**, and the brand link returns to
onboarding. Starting the onboarding chat refreshes bootstrap in place,
reveals the normal tabs, and points the brand link at that onboarding
chat. Once the first Epic lands, setup is complete and the Setup tab
disappears.

Realtime updates use `AppUserChannel` app events consumed by React. Most
events invalidate TanStack Query keys for the affected resource
(`job`, `workflow`, `epic`, `repository`, `chat`, and admin overview);
some high-churn surfaces patch cached payloads directly, including chat
message tails/control state, whiteboard snapshots, notification create
counts, and notification read state. Dashboard invalidations are
throttled and deferred while a dashboard fetch is already in flight.
Dev mode uses `solid_cable` (NOT `async`) so cross-process events work
between web and worker.

Tailwind runs in class-based dark mode (`darkMode: "class"`). The Rails
SPA layout emits `<html class="dark">` for users whose persisted theme is
dark, and React keeps that root class in sync after client-side toggles.

The dashboard JSON is assembled by `App::DashboardPayload` for the
active subject (`epic`, `job`, or `workflow`). Reads are intentionally
side-effect-light: the payload ensures only that subject's built-in
`SmartFolder` rows exist, applies ownership/smart-folder filters, and
returns current preferences without persisting navigation choices.
Preference writes go through `PATCH /api/v1/app/dashboard/preferences`
for subject defaults and, when `active_smart_folder_id` is supplied,
folder-specific view/sort slots. Built-in folder defaults layer below
saved preferences: All Epics defaults to Kanban and Landing Queue
defaults to queue-position sorting. Job list mode defaults to the Inbox
smart folder when no smart-folder id or filter is present; operators can
still request the unfiltered list with `smart_folder_id=all`. Job smart
folders are backed by `attention` preset chips: Inbox includes
actionable unread feedback, failed Jobs, open Jobs with
`landing_failure_reason`, validity review, and approval-ready Jobs; Just
failed includes both failed Jobs and open landing failures. Job rows
carry `source_chat` links and their latest Workflow snapshot through
correlated subqueries on `workflows` so the dashboard can show recent
Workflow state without joining every Workflow row into the paginated Job
query.

Chat rendering deliberately treats authors differently. Assistant,
system, proposal, and tool-facing content use the local `Markdown`
renderer so transcripts preserve lists, code blocks, tables, and inline
formatting. User-authored chat messages use `PlainText` with preserved
whitespace and word wrapping, so the UI displays exactly what the user
typed instead of interpreting numbered answers, bullets, or code-like
phrases as Markdown.

The standalone Go CLI (`cli/`) shares the app API rather than a separate
backend. `syrus login` stores the instance URL and API token in
`~/.syrus/credentials`. Running `syrus` without a subcommand lists recent
chat sessions, prefers sessions for the current checkout's GitHub repo
when it can detect one, and enters an interactive REPL. `syrus chat
CHAT_ID MESSAGE` sends a single streaming turn. Both chat paths post to
`/api/v1/app/chats/:id/message` with `Accept: text/event-stream`, render
assistant chunks as server-sent events arrive, expose proposed Jobs/Epics
for inline confirm/reject, surface queued-message state, and translate
Ctrl+C into the chat stop API instead of abandoning the Rails-side turn.

The same binary also covers operator workflows from a terminal:
`syrus status`, `syrus inbox`, `syrus checkout`, `syrus test-plan`, and
`syrus approve` are top-level shortcuts; grouped commands under
`syrus job`, `syrus epic`, `syrus repo`, and `syrus schedule` inspect and
act on Jobs, Epics, repositories, and recurring schedules. These commands
use the app-scoped JSON API where possible so ordinary users can inspect
and act on their own work; admin-only commands still call admin endpoints
such as `GET /api/v1/admin/jobs/:id` when they need cross-workflow
artifacts. Repository-aware commands detect the current GitHub checkout
from `origin`, scope lists to that repository by default, and refuse
checkout-changing operations when the local repository does not match the
Job's repository.

The Electron desktop shell (`desktop/`) uses the same credentials file
and app API as the CLI. The main process owns stored instance/token
settings, local repository path mappings, app-user Cable connection,
native notifications, unread-notification count sync, notification
inbox IPC, global hotkey registration, checkout/approval IPC handlers,
and external browser launches. It listens for app-event
`notification_created` payloads, dispatches native notifications using
the user's desktop notification preferences, and broadcasts the event to
renderer windows so they can refresh notification lists without polling
alone. The React renderer shows the compact inbox, notification inbox,
Job detail with summary and feedback tabs, repository picker, direct-Job
form, admin controls, and preferences UI. The inbox consumes the app Job
payload's
`repository_id` and `repository_slug` to group rows by repository and
link back to repository pages; checkout actions delegate to the `syrus`
CLI so the desktop app does not reimplement branch-management semantics.

Terminal sessions are owned by `User`, optionally linked to a
`Workflow`, and run on the `chat` queue through `TerminalSessionJob`.
The app API creates a `TerminalSession` with an auth token and a working
directory; the worker starts `TerminalRelay`, publishes
`relay_address`, and spawns `bash` in a PTY. The browser connects
directly to that relay socket, sends the token as the first frame, and
then exchanges JSON control frames for input/resize plus raw PTY output.
Disconnects close only the client socket while the PTY stays alive for a
short reconnect window; killing the session marks `finished_at`, the
relay polls that state, terminates the child process, and finalizes the
session outcome.

## Deployment topology

- Single-host Docker Compose is the low-friction distribution path for
  new operators. `install.sh --docker` pulls the prebuilt
  `ghcr.io/tkadauke/syrus-local` image, generates `.env` secrets on
  first run, refuses to regenerate encryption keys over an existing data
  volume, and starts web + worker containers backed by the local data
  volume. `install.sh --bare-metal` remains the macOS source install
  path. `bin/compose-up` is the source-build Compose helper for local
  development.
- `bin/publish-image` builds the distribution image, runs
  `bin/test-docker` against the freshly built image, and pushes to GHCR
  only after that integration gate passes. The Docker integration suite
  brings up an isolated Compose project and verifies database setup
  across the app/Solid databases, Active Storage on the local volume,
  worker registration and job draining, bundled Ruby/Node/Python/Go
  runtimes, and the MCP sidecar handshake.
- The production topology is two Kubernetes Deployments behind one
  Service: `syrus-web` (Puma)
  and `syrus-worker` (`bin/jobs`). The worker process supervises separate
  Solid Queue pools for `runs`, `merges`, `chat`, and `default` jobs.
  MySQL runs in its own pod.
- Ingress routes the configured app host, for example `syrus.example.com`.
- Persistent volume mounted at `$SYRUS_DATA_ROOT` (default
  `/home/rails/.syrus`) on worker pods, holding active Workflow
  workspaces at `workflows/<workflow_id>/` and provider homes under the
  agent workspace area. Web pods don't need this volume.
- Terminal relay sockets are advertised from worker-side sessions.
  Bare-metal/local development can leave `SYRUS_TERMINAL_HOST` unset and
  the relay uses `127.0.0.1`; Docker Compose points it at the worker
  service name; Kubernetes workers should advertise their pod IP so the
  web/browser path can connect to the per-session relay address. The
  relay is not routed through public ingress.
- Every web and worker process registers an `InstanceVersion` row on
  boot when `SYRUS_ROLE` is set, heartbeats every 30s, and is finalized
  on graceful exit or by `ReapStaleInstanceVersionsJob`. The admin
  version endpoint shows the request handler plus fresh instances, which
  makes rolling deploy state visible.
- Two clusters: staging (default kubeconfig) and production
  (`~/.kube/config-production`). Diagnostic recipes are in `CLAUDE.md`
  under "Debugging staging / production via kubectl".
- Kubernetes deploys use `bin/deploy` to build and push the web and
  worker images for the configured cluster architecture. That path uses
  plain `docker build` plus `docker push` through `bin/docker-image-lib`
  instead of buildx registry exporters, because the deploy path has
  observed buildx hangs after image export. Local Compose and publish
  flows still share the same helper and can opt into the registry-backed
  BuildKit cache. See CLAUDE.md "Deploy target" for platform-specific
  notes.
- Releases are cut by the CI pipeline (`.github/workflows/release.yml`) —
  a manual dispatch that computes the version, builds and signs the CLI,
  both desktop apps, and the backend image, and publishes them atomically
  (see `docs/releasing.md`). The `bin/release*` scripts are LOCAL
  build/verify tools: `bin/release` builds CLI/desktop artifacts under
  `dist/releases/<version>/<component>/` (no tagging or publishing);
  `bin/release-cli` / `bin/release-desktop` are the per-component builders;
  `bin/publish-image` builds, integration-tests, and pushes the image (used
  directly and by the workflow); `bin/release-notes` previews Claude-written
  notes. Shared version/checksum/output-dir helpers live in
  `bin/release-lib`.

## What's intentionally not here

These belong to `ROADMAP.md`; only their current status is recorded:

- **Sandboxed Docker-per-Run isolation.** Today: fresh per-Workflow clone
  on the worker filesystem; the agent is trusted not to escape.
- **Public REST / MCP API.** The sidecar is internal-only; there's no
  external auth surface.
- **Visual graders / agent-authored graders.** Today configured
  command graders from `.syrus.yml` are first-class Workflow Steps and
  the initial Workflow can collect an agent-authored reviewer test plan,
  but richer visual and agent-authored grading remains roadmap.
- **Global rate limiting.** Today only Solid Queue's per-key
  concurrency: per-repo polling, per-Job PR/rebase polling, per-Job
  RunJob serialization. No tenant-wide or process-wide cap.
- **Fully general agent MCP API.** The internal sidecar exposes only
  scoped operational tools needed by active Runs.

See `ROADMAP.md` for design notes on each.
