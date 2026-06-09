# Syrus — agent guide

A multi-user, cross-repo issue→PR automation harness. Owns the
deterministic plumbing (clones, branches, PRs, cleanup) so the
agent can focus on writing code. See `README.md` for the human pitch
and `ROADMAP.md` for milestone planning.

## Stack

Rails 8.1.3 · Ruby 3.2.3 · SQLite (dev/test) / MySQL (prod) ·
Solid Queue + Solid Cache + Solid Cable · React + TypeScript via Vite ·
TanStack Query · Tailwind via `tailwindcss-rails` · Octokit for GitHub.

## Architecture in 60 seconds

External polling drives everything — no inbound GitHub callbacks. `PollAllRepositoriesJob`
fans out to one `PollRepositoryJob` per active repository, which lists
issues with the configured trigger label. Each new labeled issue creates
a `Job` (the *thread*), which auto-creates an initial `Workflow` (the
*attempt*), which auto-enqueues its first `Step`'s `Run`. `PollAllPullRequestsJob`
does the same for PR review feedback, creating follow-up `Workflow`s on
existing `Job`s.

The state machines (AASM):

```
Job (one per issue):       open ⇄ closed
Workflow (one per attempt): queued → running → succeeded | failed | cancelled
Step (one per step):        queued → running → succeeded | failed | cancelled
Run (one per step):         queued → running → succeeded | failed | cancelled
```

`Job` carries the GitHub identifiers (issue + PR numbers, branch name) and
the credential mode captured at creation time (`app` or `pat`).
`Workflow` is the top-level unit for a single attempt; it owns a chain of
`Step`s and a shared workspace at `$SYRUS_DATA_ROOT/workflows/<workflow_id>/`.
Each `Step` dispatches to a `Steps::` handler and owns one `Run`. `Run`
carries per-attempt state — prompt, agent metadata, diff, PR copy.

`Job#kind` is `issue` (default, filed from GitHub), `cron` (fired by a
`ScheduledTask` — no issue_number, prompt pre-rendered at fire time), or
`direct` (operator-created free-form prompt, no GitHub issue or scheduled
task — prompt supplied directly at job creation). All three kinds use the
same Workflow pipeline.

### Trigger kinds

`Workflow#trigger_kind` distinguishes what an attempt is *for*:

- `initial` — first attempt on a Job (issue → branch → PR)
- `pr_comment` — review feedback follow-up; reuses the same branch
- `ci_failure`, `retry`, `manual` — operator-initiated retries
- `auto_merge` — landing-queue attempt for an approved Job; runs final
  graders, optional repair, push, and the GitHub merge path.
- `merge_train` — landing-queue attempt for a ready Epic when
  `AppSetting.merge_train_enabled` is on; builds and lands all open
  approved child PRs atomically through one integration branch.
- `rebase` — maintenance Run that rebases the PR's branch onto base
  when the PR has gone unmergeable. Skips the closed-Job guard (a
  preempted Job's external PR can still need rebases), skips
  `commit_agent_changes` (rebase rewrites history, not the working
  tree), uses `git push --force-with-lease=<branch>:<observed_sha>`
  instead of fast-forward, and skips the PR-opening step. Triggered by
  `PollAllMergeStatesJob` when a PR is `mergeable: false` and we control
  the head branch.
- `stack_rebase` — maintenance Run that rebases a dependent PR stack
  branch-by-branch, force-pushes each updated branch, then resumes
  landing for approved stack Jobs.

### Per-Workflow pipeline (`app/jobs/run_job.rb`, `app/services/workflows/`, `app/services/steps/`)

Each Workflow runs a named chain of Steps. Workflow definitions live in
`app/services/workflows/`; step handlers in `app/services/steps/`. All Steps
in a Workflow share one `WorkflowWorkspace` (shallow clone at
`$SYRUS_DATA_ROOT/workflows/<workflow_id>/`). Workspace lifecycle is tied to
Workflow terminal transitions (not per-Step ensure). `WorkflowWorkspacePruneJob`
sweeps old terminal workspaces after 7 days.

Current chains:

```
initial:     prepare → retry_until(implement → graders) → summarize → pr_open
pr_comment:  prepare → retry_until(respond → graders) → summarize_amend → push
ci_failure:  prepare → analyze_and_fix → summarize_amend → push
retry:       prepare → retry_until(implement → graders) → summarize → pr_open
resume:      manual
rebase:      auto_rebase → agent_rebase → force_push
stack_rebase: stack_auto_rebase → stack_agent_rebase → stack_force_push
auto_merge:  mergeability_preflight → prepare → retry_until(graders, repair: landing_fix) → push → auto_merge
merge_train: merge_train_assemble → merge_train_build → prepare → retry_until(graders, repair: landing_fix) → merge_train_land
```

Key steps:

- **`prepare`** — Runs `bundle install`, `npm ci`, etc. from `.syrus.yml`
  or auto-detects from lockfiles. Env is scrubbed to a safe forward list
  so the worker's Bundler config doesn't pollute the target repo's install.
  Per-command timeout: 10 minutes. Succeeds with "nothing to do" if the
  repo has no setup commands — chain shape stays uniform. `Repository#prepare_enabled`
  can disable the step for all workflows on that repo; the
  `syrus-skip-prepare` issue label disables it for that Job. Skips are
  recorded in Workflow artifacts and logged on the first Run.
- **`implement`** / **`respond`** / **`analyze_and_fix`** — Agentic steps:
  invoke the Workflow's configured `AgentProviders::*` adapter. Claude uses
  `AgentInvocation`/`claude --print`; Codex uses `CodexInvocation`/`codex exec`.
  Pluggable `runner:` for tests.
- **`auto_rebase`** / **`agent_rebase`** / **`force_push`** — Rebase chain:
  first try deterministic `git rebase`; if clean, cancel only `agent_rebase`
  and still `force_push`. On conflict, `agent_rebase` resolves it, then
  `force_push` updates the PR branch with an explicit `--force-with-lease`
  against the branch SHA Syrus observed.
- **`grader_fanout`** / **`grader`** / **`grader_collect`** — Read grader
  commands from `.syrus.yml`, materialize one immutable `grader` Step per
  configured grader, and aggregate required failures. `Workflows::RetryUntil`
  appends bounded repair/check iterations using `AppSetting.grade_max_iterations`.
- **`landing_fix`** — Agentic repair step inside auto-merge. It runs only
  after final graders fail on the exact PR branch Syrus is about to land;
  successful repairs are pushed before the merge API call.
- **`mergeability_preflight`** — Non-agentic auto-merge gate that refreshes
  GitHub mergeability, runs a local rebase preflight when GitHub is still
  computing, dispatches rebase workflows for conflicts, and can skip already
  validated landing checks for the same PR head/base pair.
- **`auto_merge`** — Non-agentic landing step. Transient GitHub merge
  failures defer the Job back to `approved`; right after Syrus pushes it waits
  briefly for GitHub's transient `mergeable_state` to settle before deferring.
  A 405 saying the PR can't be rebased dispatches the rebase path instead of
  treating the landing attempt as a terminal failure.
- **`merge_train_assemble`** / **`merge_train_build`** / **`merge_train_land`** —
  Epic merge-train steps. Assemble requires every open child Job to be approved
  and under `AppSetting.merge_train_max_size`; build starts from the base tip
  and rebases member branches onto the growing integration tip in dependency
  order. Build tries a mechanical `git rebase` first; on conflict it hands
  that in-progress rebase to the agent, which must resolve conflicts and run
  `git rebase --continue` until the same rebase finishes. Syrus verifies by
  end-state (scratch branch checkout, clean worktree, integration branch is an
  ancestor), not by rebase-internal refs like `REBASE_HEAD`; land pushes the
  integration branch, merges one integration PR into base, then comments on
  and closes the member PRs.
- **`summarize`** / **`summarize_amend`** — Short agentic step that
  asks the agent to call `submit_summary`.
  If the implement step already called `submit_summary` (artifacts contain
  `agent_pr_title`), the summarize step skips the agent call entirely and
  promotes artifacts directly — saving a full agent turn.
- **`pr_open`** / **`push`** —
  Non-agentic: run service code (`PullRequestOpener`, `git push`, etc.).

**MCP sidecar** — `bin/syrus-mcp-sidecar`, spawned by `claude` over stdio
via a per-step `mcp.json` tempfile. Exposes `read_live_state(detail)`,
a read-only current Job/Workflow/Run/queue/chat snapshot for agents, and
`submit_summary(pr_title, pr_body, summary)`, which writes directly onto
the Workflow's `artifacts` bag and appends a `JobLog` audit line.
The config key and binary basename must match (`syrus-mcp-sidecar`) so the
agent can invoke the tool name registered in the MCP config. See
`app/services/syrus_mcp/`.

**PR copy degradation** — `open_pull_request_if_missing` reads
`workflow.artifacts["pr_title"]`/`["pr_body"]` first; falls through to
`PrSummarizer`; falls through to a templated default. Path 1 is the goal.

**Diff capture** uses `git diff <default_branch>...HEAD` (three-dot — what
GitHub's "Files changed" tab shows) to avoid pollution when the base branch
moves forward while the syrus branch is open.

**Dependency gating** — issue bodies can include lines like
`Depends-on: #123` / `Blocked-by: owner/repo#456`. `JobDependencyParser`
resolves those to existing Syrus Jobs for the same user, creates parsed
`JobDependency` rows, and blocks `StepDispatcher.start_workflow` until every
dependency closes successfully (`pr_merged`, `external_pr_merged`,
`pr_approved`, or `no_changes`). Same-Epic dependencies also count as
satisfied once the upstream Job is `approved` or `landing`, so a stack
inside one Epic can keep flowing while the landing queue serializes merges.
Operators can add/remove manual dependencies; parsed dependencies are kept
for audit, and only admins can override the gate.

**Epic merge-train landing** — when `AppSetting.merge_train_enabled` is true,
approved Epic child Jobs do not land one-by-one. They remain `approved` with
blocked reason `waiting for Epic merge-train` until every open sibling is
approved, then Syrus lands the Epic as an all-or-nothing `merge_train`
Workflow. A failed train reverts members out of `landing` and observes a
30-minute retry cooldown so an unrepaired integration conflict does not churn
the landing queue.

**PR feedback watermarking** tracks both `last_seen_comment_at` and
`last_feedback_addressed_at`; successful `pr_comment` workflows mark the
newest addressed comment, and future polls use the later timestamp as the
cutoff so already-handled feedback is not re-enqueued.

**Failure resilience** — failed Runs persist a `RunFailureClassification`
from diagnostics, recent logs, spawned process outcomes, and agent outcome.
`AutoRetryScheduler` may retry transient failures up to three times with
5m/20m/1h backoff, either from the failed Step while the workspace remains
or as a fresh retry Workflow. Failed agentic runs with captured sessions can
resume from the failed Step instead of starting over. `ProviderCircuitBreaker`
suppresses automatic retries/CI repair during provider-wide transient outages.

### Scheduled tasks

`ScheduledTask` lets the operator attach recurring or one-shot agent
prompts to a repository — no GitHub issue required. `kind=cron` uses a
5-field cron expression (validated to fire at most once per hour);
`kind=one_shot` uses a `fire_at` datetime. Each task has a random
`minute_offset` seeded at create time so two tasks with the same nominal
schedule never collide on the wall clock. Tasks can optionally reference
a `CronTemplate` (`app/models/cron_template.rb`) — a per-user reusable
prompt+schedule config that multiple ScheduledTasks can share.

`PollScheduledTasksJob` (runs every minute) evaluates due tasks and fires
them. Each fire creates a `Job` with `kind=cron` (linked via
`scheduled_task_id`, no `issue_number`) and an initial `Run` whose prompt
is pre-rendered at fire time (variables `{{repo_slug}}`,
`{{last_fired_at}}`, etc.). The standard RunJob pipeline takes over from
there on branch `syrus/scheduled-<task_id>-<job_id>`.

`pr_pileup_policy` controls what happens when the previous fire's PR is
still open at next tick: `skip` (default, don't fire), `pile` (fire
anyway), `replace` (cancel the old Job and fire). Auto-pause kicks in
when consecutive failure count hits the `AppSetting.max_job_failures`
threshold; the operator must unpause the task to re-enable it.

"No changes" is the explicit happy path for cron Jobs — the agent
surveys, calls `submit_summary` with a one-line note, and the Job closes
with reason `no_changes`.

### Live UI

Authenticated operator pages are React routes rendered by
`app/views/spa/show.html.erb` and backed by `/api/v1/app/*` JSON
controllers. React uses TanStack Query for server state and
`AppUserChannel` app events for live invalidation or compact payload
updates, notably chat message tails and whiteboard changes.

Dev and prod use `solid_cable` (NOT `async`) so browser app events work
across web/worker processes.

## Conventions

- **Public website/docs stay current.** Product-facing behavior changes
  must update `website/` in the same PR. If a change affects what Syrus
  is, why someone would use it, how to get started, a workflow, a feature,
  configuration, credentials, operations, schedules, chats/direct Jobs,
  troubleshooting, or an API surface, update the matching page under
  `website/src/pages/` or `website/src/content/docs/`. Prefer updating an
  existing page over adding a parallel one; if the navigation contract
  changes, update `website/README.md` too. PRs that add product behavior
  while leaving the public docs stale are incomplete.
- **Prompts** all live under `app/services/prompts/` as PORO classes
  (`Prompts::Initial`, `Prompts::PrFeedback`, `Prompts::PullRequestSummary`,
  `Prompts::SubmitSummaryInstructions`, `Prompts::Rebase`,
  `Prompts::ScheduledTask`, `Prompts::DirectJob`). Each has a `to_s`. Compose
  by appending; never inline prompt text in jobs/services.
- **Website/docs audit.** If no website/docs update is needed, the PR body
  must say why so reviewers can audit the call. `AGENTS.md` is a symlink to
  `CLAUDE.md`; preserve that relationship and edit the shared guidance through
  `CLAUDE.md`.
- **Workflow/Step registries** — `Workflow::TriggerKind` and `Step::Kind`
  are the single source for trigger/step metadata: valid values, handler or
  template class, UI label/style, and whether a step is agentic. Add new
  trigger kinds or step kinds there instead of scattering constants in
  helpers/services.
- **Encrypted attributes** — `User#github_token`, `User#claude_oauth_token`
  use Active Record Encryption. Means `RAILS_MASTER_KEY` is required in
  any process that touches them. Smoke tests inside containers without
  the key will fail at User creation — by design. Production may supply
  `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`,
  `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, and
  `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` instead of credentials;
  set all three together or boot fails.
- **AASM events on Run** — call `start!`, `succeed!`, `fail!`, `cancel!`,
  always followed by `save!` (callbacks set timestamps but don't persist).
  See `Run` model.
- **AASM event guards: ALWAYS `may_X?` before `state_X!`.** The Job
  (and Workflow, and Step) AASM machines run with
  `whiny_transitions: false` — `job.approve!` on a non-approvable Job
  silently no-ops. That made the auto-approval bug (`7fb6aae`)
  invisible until a Job got stuck. Pattern:
  ```ruby
  job.approve!(via: "operator", by_user: user) if job.may_approve?
  ```
  When you need the transition to be definite (not "skip silently if
  not legal"), wrap it in a service that re-checks state and dispatches
  side effects — `LandingQueueProcessor.try_land!` is the canonical
  example. The State machine surface for Job is documented in
  `docs/job-state-audit.md`.
- **Per-Job concurrency** — `RunJob` uses Solid Queue's `limits_concurrency`
  keyed on `job_id` so two Workflows on the same Job never overlap. (Was
  per-repo; changed because the shared WorkflowWorkspace path is per-Workflow-id,
  so the collision risk is within a Job, not across repos.)
- **SolidQueue queues** — `runs` for normal agent workflow Runs; `merges`
  for auto-merge, rebase, and stack-rebase workflow roots; `chat`
  (dedicated low-concurrency worker) for ChatTurnJob and ChatWorkspaceJob;
  `default` for pollers, app-event broadcasts, and reaper jobs. Splitting
  prevents long RunJobs from starving landing, chat, the reaper, and UI
  broadcasts.
- **Per-user max-turns** — `User#agent_max_turns` (default 200, range
  0–1000). `0` means no `--max-turns` flag is passed to claude (the
  per-run 30-minute timeout still bounds runaway loops). Threaded through
  RunJob → AgentInvocation for both regular and rebase runs.
- **Agent provider selection** — `User#agent_provider` defaults new Jobs
  and direct Jobs; `Repository#agent_provider` overrides it for that repo
  and drives repository-level bulk retries. Per-Job actions and new direct
  Jobs can explicitly choose a configured provider. Always pass the chosen
  provider through to the new Workflow/Run instead of relying on later inference.
- **GitHub credentials** — repositories prefer an active GitHub App
  `Installation`; `GithubClient.for` falls back to the user's PAT if the
  installation is removed or absent. Repository owner changes relink through
  `InstallationLinker`; Jobs persist the resulting `credential_mode` for
  operator visibility.
- **Clean-rebase grade carry-forward** — `Repository#trust_clean_rebase_grade`
  is off by default. When enabled, a clean `rebase` Workflow may record a prior
  green landing validation for the new head/base pair instead of forcing
  auto-merge to re-run required graders.
- **GitHub issue actions** — Repository pages can list GitHub issues and
  comment, close, delegate (add the trigger label), or bulk delegate/close
  them through `GithubClient`. Keep single and bulk paths in sync.
- **Syrus Epic issue markers are body-only.** `PollRepositoryJob` parses
  `Epic:` markers from the GitHub issue body, not from the title. When filing
  a GitHub issue that should become a Syrus Epic, put a standalone
  `Epic: <epic name>` line near the top of the body. A title like
  `Epic: ...` is only display text and will be ingested as a normal Job. Child
  Jobs under an Epic need a standalone `Epic: #<issue-number>` body line. When
  filing child issues immediately after an Epic issue, first verify the Epic
  exists through the admin API or create the Epic via the admin API; otherwise
  the children remain in `pending_epic_ref`.
- **GitHub identifiers are links.** Whenever the UI renders a GitHub issue
  or pull request identifier (`#123`, `PR #123`, `owner/repo#123`), make it
  clickable to the matching GitHub page when a URL can be derived. Plain
  identifiers are only acceptable when the target is genuinely unknown.
- **Form validation UI** — React forms should use native validity
  attributes plus route-local error rendering.
- **Close icons** — React close/dismiss/remove controls should render the
  shared `CloseIcon` component (`app/frontend/components/CloseIcon.tsx`),
  not a literal `x` or `×` text node. Keep the accessible label explicit
  (`Dismiss notification`, `Close`, `Remove <thing>`, etc.) and size the icon
  with the component's `className` prop.
- **Per-user scheduling pause** — `User#scheduling_paused` (boolean).
  `PollScheduledTasksJob` skips paused users entirely. Operator can toggle
  via admin UI; user can toggle in `/credentials/edit`.
- **Per-Job priority** — `Job#priority` is `high` / `medium` (default) /
  `low`. Converted to SolidQueue integers at enqueue time via
  `Job#solid_queue_priority` (high→0, medium→10, low→20); the
  `Run#enqueue_run_job` path and paused-run re-enqueue in `RunJob` both
  use it. Admin API exposes `priority` on job list and detail responses.
- **Execution ownership** — `Workflow#user_id` and `Run#user_id` must match
  the parent Job owner. Creation paths default from `job.user`; tests and
  manual records should do the same because `RunJob` refuses mismatched
  execution graphs.
- **Job/Epic ownership** — `owner_user_id` is the durable assignee used
  by dashboard scopes, admin APIs, and Epic-owned child Jobs. Job
  `claimed_by_user_id` / `claimed_at` is a lightweight app claim shown in
  the dashboard and Job detail; only the current claimant can release it.
  Keep `mine`, `team`, `claimable`, and explicit `user` scopes aligned
  across dashboard payloads, API serializers, and React filters.
- **Pagination standard** — all paginated list views use the same UI:
  "Showing X–Y of Z" counter on the left; bordered pill buttons
  (`px-3 py-1 border border-gray-300 rounded hover:bg-gray-50`) for
  Previous/Next on the right with `gap-2` between them; disabled
  direction rendered as a grayed `<span>` with `border-gray-200
  text-gray-300` (never hidden). Wrapper: `flex items-center
  justify-between text-sm text-gray-600`. The controller exposes
  `@total_<collection>` and reads `PER_PAGE` from the controller constant;
  the view computes `first_item`/`last_item` inline. Only show the
  pagination block when `total_pages > 1`.
- **Migration timestamps come from the generator. No exceptions.**
  Always create migrations with `bin/rails generate migration <Name>`.
  Never hand-write a `db/migrate/YYYYMMDDHHMMSS_*.rb` filename, never
  copy a sibling migration and bump the digits, never reuse a timestamp
  you saw in another branch's PR. Hand-rolled timestamps collide:
  two branches that both pick `20260513120100` produce identical
  `schema_migrations` rows on the first environment to merge them, and
  the second branch's file then crashes the deploy with
  `Mysql2::Error: Table 'X' already exists`. Recovery is manual
  `UPDATE schema_migrations SET version = '<new>' WHERE version =
  '<old>'` SQL in every environment (dev, test, staging, production) —
  we have paid for this several times. This applies to backfills,
  schema-version bumps, no-op migrations, every kind. If you regret a
  hand-written file you already committed, delete it, regenerate via
  the generator, and rewrite the diff onto the new file before
  pushing.
- **Migrations are idempotent.** Wrap every `add_column`,
  `remove_column`, `add_reference`, `remove_reference`, and
  `add_index` in an existence guard:

  ```ruby
  def up
    add_column :jobs, :approved_at, :datetime unless column_exists?(:jobs, :approved_at)
    add_reference :jobs, :approved_by_user, null: true, foreign_key: { to_table: :users } unless column_exists?(:jobs, :approved_by_user_id)
    add_index :jobs, :approved_at unless index_exists?(:jobs, :approved_at)
  end
  ```

  Why: production migrations occasionally crash partway through (OOM,
  pod eviction, transient lock contention, etc.) and don't record the
  version in `schema_migrations`. On retry the bare `add_column` dies
  with `Mysql2::Error: Duplicate column name`, the init container
  loops, the deploy hangs. Idempotent migrations recover instead. The
  same applies to `down`: guard with `if column_exists?` so a rollback
  on a partial-state DB doesn't crash. `add_table` / `drop_table` are
  less critical (table creation is more atomic) but follow the pattern
  anyway — `create_table :foo do |t|` becomes `create_table :foo,
  if_not_exists: true do |t|` with no behavior change.
- **JSON columns can't have defaults on MySQL 8.** `add_column :jobs,
  :payload, :json, default: {}, null: false` runs fine on SQLite (dev /
  test) and crashes the production migration with `BLOB, TEXT, GEOMETRY
  or JSON column 'payload' can't have a default value`. The pattern
  that works:

  ```ruby
  add_column :jobs, :payload, :json
  execute "UPDATE jobs SET payload = '{}' WHERE payload IS NULL"
  change_column_null :jobs, :payload, false
  ```

  Add an `after_initialize` callback on the model that seeds `{}` for
  new records so the column stays non-null going forward without a DB
  default. Copy an existing guarded JSON-column pattern.
- **Three-dot diffs only** — `git diff <base>...HEAD`, never two-dot.
  Lesson learned the hard way (commit `67b2bf9`).
- **Clones live outside the repo** — under `$SYRUS_DATA_ROOT` (default
  `~/.syrus`). The agent's `chdir` MUST NOT be inside the operator's
  checkout. (Lesson from commit `ced3a65`.)
- **Tests** — RSpec, no FactoryBot. Lightweight `Factories` module in
  `spec/support/`. WebMock + VCR for GitHub. The agent runner is stubbed
  via `RunJob.agent_runner` and `PrSummarizer.runner` test seams; never
  shell out to real `claude` from tests.
- **Per-instance version tracking (`InstanceVersion`)** — Every
  web pod and worker pod registers a row in `instance_versions` on
  boot via `InstanceVersionSupervisor` (started from a
  `to_prepare` initializer when `ENV["SYRUS_ROLE"]` is set —
  manifest-driven, skipped in local/test/console). The row carries
  hostname, role, git SHA (from `ENV["GIT_SHA"]` baked into the
  image by `bin/deploy`), started_at, and a heartbeat thread bumps
  `last_heartbeat_at` every 30s. `at_exit` stamps `finished_at`
  on graceful SIGTERM; `ReapStaleInstanceVersionsJob` (every
  minute) finalizes rows whose heartbeat hasn't moved for 5+ min
  (SIGKILL / OOMKill / node eviction). `GET /api/v1/admin/version`
  returns the request handler's identity plus every fresh
  instance — useful for confirming a deploy has finished rolling
  (during a deploy you see both old + new SHAs in the
  `instances` array until the old pods drain).
- **REST Admin API** — `GET /api/v1/admin/overview`, `/stuck`, `/jobs`
  (filterable by `pr_number`, `issue_number`, `repo`, `state`, `user`,
  `has_active_workflow`, `failed_in_last_24h`), `/jobs/:id`, `/workflows/:id`,
  `/runs` (cross-Job flat list; filterable by `state`, `trigger_kind`, `job_id`,
  `since`), `/queue`, `/processes` (subprocess inventory; filters
  `state=running|finished|all`, `kind`, `hostname`, `run_id`, `workflow_id`,
  `since`; `POST /processes/:id/kill` stamps `kill_requested_at` for the
  cross-pod kill switch), etc. Bearer-token auth via `User#api_token`
  (deterministic-encrypted column). Nested serializers are resilient — a single
  bad row emits `{ error_serializing: "..." }` rather than 500ing the whole
  response (`Admin::JobStateSerializer`). See `app/controllers/api/` and
  `app/services/admin/`.
- **Subprocess inventory (`SpawnedProcess`)** — every subprocess spawned
  through `ProcessRunner` (agent CLIs, graders, git, prepare) registers a
  row, heartbeats on every output chunk, and finalizes on exit. `kind`
  is a strict CONSTANT enum (`SpawnedProcess::KINDS`) — new spawn sites
  must register a kind. The operator-facing list lives at `/admin/processes`
  with kind/hostname/run filters + per-row Kill button. Kill stamps
  `kill_requested_at`; the owning worker's `ProcessRunner` polls the row
  once per second and terminates the local pid. `SpawnedProcess#host_metrics`
  reads `/proc/<pid>/{status,stat}` on Linux for live CPU/RSS readout.
  Two-layer cleanup catches orphans without timeout-based guessing:
  `SpawnedProcessSupervisor` is an in-process ticker thread that
  ProcessRunner.new lazy-starts on first call; every 30s it walks
  own-hostname rows and finalizes any whose pid is gone (detects
  Ruby-thread death / OOM-killed subprocesses inside an otherwise-
  alive pod). `ReapOrphanedSpawnedProcessesJob` (every minute) handles
  the cross-hostname case — finalizes rows whose hostname isn't in
  the current `SolidQueue::Process.distinct.pluck(:hostname)` set
  (detects dead pods within ~5 min of SQ pruning the worker). Both
  paths use conditional `update_all(WHERE finished_at IS NULL)` so
  they race safely with each other and with ProcessRunner's own
  finalize call. `SpawnedProcessPruneJob` (daily 3:20am) deletes
  finished rows past 7 days.

## Tests are not optional

**Every PR must include tests for the behavior it changes. PRs without
tests will not be merged.** This applies to every kind of change —
new features, bug fixes, refactors, plumbing, "trivial" tweaks. If
the change is too small to justify a test, the change is too small
to need a PR; fold it into something testable.

What "with tests" means here:

- **New behavior** → a spec that fails without your change and passes
  with it. If you can't write one, the behavior isn't well-defined yet.
- **Bug fix** → a regression spec that reproduces the bug. The fix
  without the spec is half a fix; nothing stops it from regressing.
- **Refactor** → existing specs must still pass, AND if the refactor
  touches an under-tested area, add the missing coverage as part of
  the same PR. "I didn't change behavior" is not a free pass.
- **Anything touching the agent loop, RunJob, AgentInvocation, MCP,
  or the polling jobs** → exercise it with the existing test seams
  (`RunJob.agent_runner`, `PrSummarizer.runner`, WebMock for Octokit,
  stubbed AgentInvocation Result). These seams exist precisely so
  every code path can be tested without shelling out to real claude
  or hitting real GitHub.

If the test would require infrastructure that doesn't exist in the
test environment (e.g. SolidQueue tables aren't loaded in test —
test runs single-database), stub the boundary and say so in a
comment. Don't skip the test.

The full suite runs in ~10s. There is no excuse.

## Testing on the deployed instance

To exercise a change end-to-end, configure a low-stakes GitHub test
repository that your deployed Syrus instance polls. Set
`SYRUS_TEST_REPO` to its `owner/name` slug, then file an issue on that
repo with the `syrus` label — the deployed Syrus instance picks it up
and opens a PR there:

```
gh issue create -R "$SYRUS_TEST_REPO" --label syrus \
  --title "..." --body "..."
```

For Syrus Epics, the body must contain the marker line. The title alone is not
enough:

```
Epic: <epic name>

## Goal
...
```

Child issues that belong to that Epic use `Epic: #<epic-issue-number>` in
their body. If you create the Epic and child issues in one batch, verify the
Epic record exists in Syrus before filing children, or create the Epic through
the admin API first.

Don't run `bin/dev` and stub things to simulate the agent — file a
real issue and watch the real flow. Test issues should be small
(single-PR scope), low-stakes, reversible, and describe real (if
frivolous) improvements — the agent actually implements them.

**Now the important part: be actually funny.** The model defaults
to a tepid productivity-blog register — bullet points, neutral verbs,
"considerations." For test-repo issues, override that hard. The
target is "fun to read," not "looks like a Linear ticket." Specifically:

- Lean into the namesake's mock-Roman gravitas. Frame trivial UI
  tweaks as moral obligations to a long-dead aphorist. Treat
  six-line static Latin footers like constitutional crises.
- The "Out of scope" section is comedic gold — list specific,
  absurd things the agent must NOT build. Use it.
- Running bits are good. Callbacks are good. Lampshaded
  over-engineering is excellent. Deadpan absurdity beats winking.
- Give the agent attitude in the body. It will not file a complaint.

The model is genuinely good at this when you let it. The repo is
usually private, the audience is future-you and the agent that picks it up.
Make it a good time. If the issue body reads like something you'd
actually post in a customer-facing tracker, you've under-reached.

## Debugging deployed environments via kubectl

Use the kubeconfig, namespace, and deployment names for your own
Syrus deployment. Keep them in env vars so examples stay portable:

```bash
export SYRUS_KUBECONFIG="${SYRUS_KUBECONFIG:-$HOME/.kube/config}"
export SYRUS_NAMESPACE="${SYRUS_NAMESPACE:-syrus}"
kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" get pods
```

**Pod label gotcha:** Syrus manifests commonly label pods
`name=syrus-worker` / `name=syrus-web`, NOT `app=...`. Adjust the
selector if your deployment uses different labels:

```bash
POD=$(kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" \
       get pods -l name=syrus-worker -o jsonpath='{.items[0].metadata.name}')
```

**Logs.** The container name is `syrus-worker` (with a `fix-perms`
init container — `kubectl logs` complains about "defaulted to" if
you don't pass `-c`). Worker logs are noisy with ActiveJob
serialization; grep for the bits you need:

```bash
kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" \
  logs deployment/syrus-worker --tail=500 \
  | grep -E "PollAllMergeStates|PollMergeStateJob|PollRebaseJob|preempted|RunJob|FAIL"
```

**Rails console / runner.** Don't try to inline complex Ruby into
`bin/rails runner '...'` — kubectl's shell escaping mangles
backslashes inside string literals (`\1` regex backrefs, `\"` escapes
in dig calls, etc). Write the script to `/tmp/script.rb` locally,
`kubectl cp` it in, `bin/rails runner /tmp/script.rb`:

```bash
POD=$(kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" \
       get pods -l name=syrus-worker -o jsonpath='{.items[0].metadata.name}')
kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" \
  cp /tmp/diagnose.rb $POD:/tmp/diagnose.rb -c syrus-worker
kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" \
  exec $POD -- bin/rails runner /tmp/diagnose.rb
```

**Useful diagnostic recipes** (run via the pattern above):

- *Active / zombie Runs* — `Run.where(state: %w[queued running])`.
  A "running" Run whose worker process is dead = zombie;
  `ReapStaleRunsJob` (runs every minute) handles these automatically.
- *Solid Queue history for a Run id* — `SolidQueue::Job.where(class_name: "RunJob")`
  filtered by `j.arguments&.dig("arguments")&.first == run_id`.
  Look for `j.failed_execution&.error&.dig("message")` for the death cause.
- *Bare clone worktree state* — `git worktree list --porcelain`
  inside `/syrus-home/.syrus/clones/<repo_id>.git`. Don't use
  `--verbose` with `--porcelain` (mutually exclusive in git 2.39).
  For real ground truth, walk `<bare>/worktrees/*` directly — list
  hides corrupted-HEAD entries.
- *Held semaphores (concurrency locks)* —
  `SolidQueue::Semaphore.all` — keyed `RunJob/job:<id>` etc.
  Stale locks past `expires_at` get released on next dispatcher tick.

**Token redaction is on the DB-write path, not the read path.** If
you query `JobLog.chunk` or `SolidQueue::FailedExecution.error` in
the rails runner *before* a redaction-aware build is deployed, you
will see plaintext tokens. **Never copy that output to chat.** When
scrubbing, write a redaction script (regex
`%r{(https://x-access-token:)[^@\s]+(@)}`) and run it in-process via
`kubectl cp` + `bin/rails runner` — same pattern as diagnostics.

**Deploys SIGKILL in-flight Runs.** Every `bin/deploy` rolling
restart kills any active RunJob mid-perform after the K8s grace
period (~30s). RunJob's `ensure` cleanup may not finish; orphan
worktrees and zombie Runs can accumulate. `ReapStaleRunsJob` marks dead
Runs failed and schedules the same auto-retry path used for other failures;
agentic runs with captured sessions resume from the failed Step when possible.
If you see a "refusing to fetch into branch X checked out at /worktrees/N"
error post-deploy, it's a stale registration — clean by walking
`<bare>/.git/worktrees/*` and force-removing whose Run is terminal-or-zombie.

## Workflows

Local dev:

```
bin/setup          # initial install + DB
bin/dev            # foreman: web + worker + tailwind:watch
bin/rspec          # Ruby suite (~2500 examples)
bin/rspec spec/jobs/run_job_spec.rb   # one file
bin/test-react     # React/Vitest suite + TypeScript typecheck
bin/test           # Ruby and React suites; reports separately
```

React tests run through Vitest and TypeScript. Use `bin/test-react` for
frontend-only changes, or `bin/test` to chain Ruby and React.

`bin/rspec` and Rails boot load `config/syrus_bundle_env.rb` before
Bundler setup so prepared bundles under `.syrus/deps/bundle` or
`vendor/bundle` work. Ruby grader commands in `.syrus.yml` intentionally
run `bundle config set --local path vendor/bundle && (bundle check ||
bundle install --jobs 4)` before Rails/RSpec checks; keep that pattern
when editing graders.

Docker (production image):

```
docker build --platform linux/amd64 -t syrus:amd64 .
```

The image is single-purpose (worker pod overrides CMD to `["./bin/jobs"]`);
web pod uses the default `./bin/thrust ./bin/rails server`. See
"Deploy target" below for the amd64 / Apple Silicon gotcha.

Deploying to Kubernetes:

```
bin/deploy                # default deployment target
bin/deploy --staging      # staging target, if configured
bin/deploy --production   # production target, if configured
bin/deploy --skip-build   # assume :<sha> already pushed
```

Reads the GHCR PAT from `$GHCR_TOKEN` or
`~/.config/syrus/ghcr-token` (chmod 600). Builds the configured image
platform, pushes the configured image repository tags, runs
`kubectl rollout restart` on `syrus-web` and `syrus-worker`, and waits
for rollout status. Configure kubeconfigs, namespaces, registry, and
image repository for your own environment before relying on this script.

## Deploy target

Build images for the CPU architecture used by your cluster nodes
(commonly `linux/amd64` or `linux/arm64`). On Apple Silicon, make sure
your Docker/buildx setup can build the target platform efficiently; QEMU
emulation can make cross-architecture builds much slower.

Required runtime env:

- `RAILS_MASTER_KEY` — credentials decryption unless all three
  Active Record encryption env keys are provided separately
- `SECRET_KEY_BASE` — sessions, signed cookies
- `DB_HOST`, `SYRUS_DATABASE_PASSWORD` — primary MySQL
- `SYRUS_DATA_ROOT` — defaults to `/home/rails/.syrus`. Mount a PVC
  here on worker pods so the bare-clone cache survives restarts.
  Web pods don't need this volume.

## Things that bit us (don't repeat)

- **`claude --mcp-config` is variadic.** It consumes positional args
  until the next flag, so it MUST be slotted between two flags — never
  immediately before the prompt. (Commit `d9d094e`.)
- **Action Cable's `async` adapter is process-local.** Use `solid_cable`
  in dev (`config/cable.yml`) so app events emitted by `bin/jobs` reach
  browser subscribers connected to the Rails server.
- **`db:prepare` errors loudly** when only the primary DB is reachable
  — it tries cache/queue/cable too. The primary still migrates fine.
  Inside containers without all four MySQLs, `|| true` past the error.
- **`BUNDLE_WITHOUT="development"` doesn't exclude `:test`** — use
  `"development:test"` (colon-separated). The Rails 8 default is wrong.
  (Fixed in commit `77cae32`.)
- **Non-idempotent migrations hang the deploy on partial retry.** Any
  bare `add_column` / `remove_column` / `add_reference` will die with
  `Mysql2::Error: Duplicate column name` (or its missing-column twin)
  if a previous deploy attempt got partway through, added the column,
  and then crashed before `schema_migrations` was updated. The init
  container then crashloops indefinitely. Always guard with
  `column_exists?` / `index_exists?` — see Conventions.
- **JSON columns can't have a DB default on MySQL 8.** `add_column :t,
  :c, :json, default: {}` works on SQLite, crashes prod with `BLOB,
  TEXT, GEOMETRY or JSON column ... can't have a default value`. Add
  nullable, backfill `{}` via `execute`, then `change_column_null`,
  with an `after_initialize` seed on the model. See Conventions.
- **Fresh production databases migrate from zero.** Production sets
  `config.active_record.schema_format = :sql` because the checked-in
  `db/schema.rb` is generated by SQLite. Do not rely on schema-load
  behavior for MySQL; migrations must be valid from an empty database.
- **Hand-written migration timestamps collide across branches.** Two
  PRs both picking `20260513120100_*.rb` will install identical rows
  in `schema_migrations` on whichever environment merges them first,
  and the second one's table-create then 500s on deploy. Always use
  `bin/rails generate migration` — see Conventions. Recovery is
  hand-edited `UPDATE schema_migrations` SQL in every environment,
  which is exactly the kind of toil this rule exists to prevent.

## Key files at a glance

```
app/jobs/run_job.rb                          # the orchestrator (dispatches to Steps::*)
app/services/workflows/                      # Workflow chain definitions (initial, retry, etc.)
app/services/steps/                          # per-Step handlers (prepare, implement, summarize, …)
app/services/steps/base.rb                   # shared workspace + AgentInvocation + MCP config
app/services/workflow_workspace.rb           # per-Workflow clone lifecycle (replaces JobWorkspace)
app/services/agent_invocation.rb             # claude subprocess + stream-json parser
app/services/git_runner.rb                   # streaming git wrapper
app/services/admin/job_state_serializer.rb   # shared Workflow→Step→Run serializer for admin API
app/services/github_app_installation_syncer.rb # sync GitHub App installations
app/services/installation_linker.rb          # links repositories to installations by owner
app/services/job_dependency_parser.rb        # parses Depends-on / Blocked-by issue lines
app/services/syrus_mcp/sidecar.rb            # MCP::Server boot + SIGTERM trap
app/services/syrus_mcp/submit_summary_tool.rb # the one MCP tool (writes to Workflow#artifacts)
app/services/prompts/                        # all agent prompts (PORO)
app/services/pr_summarizer.rb                # second-shot fallback
app/jobs/poll_*.rb                           # polling jobs (cron-style; see config/recurring.yml)
app/jobs/reap_stale_runs_job.rb              # kills zombie Runs every minute
app/jobs/workflow_workspace_prune_job.rb     # daily sweep of old terminal workspaces
app/models/{job,run,workflow,step}.rb        # core models + AASM
app/models/{repository,user}.rb             # repo + user (user has api_token, cron_templates)
app/models/{installation,job_dependency}.rb  # GitHub App installs + Job DAG edges
app/models/scheduled_task.rb                 # cron/one-shot task attached to a repo
app/models/cron_template.rb                 # per-user reusable schedule+prompt template
app/controllers/api/                         # REST admin API (Bearer-token auth)
bin/syrus-mcp-sidecar                        # Ruby binstub, claude spawns this
bin/jobs                                     # Solid Queue worker entry
config/database.yml                          # 4-DB prod (primary/cache/queue/cable)
config/queue.yml                             # SolidQueue: `runs` + `chat` + `default` worker split
config/recurring.yml                         # Solid Queue recurring job schedule
ROADMAP.md                                   # milestone plan + future work
```
