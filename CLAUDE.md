# Syrus — agent guide

A multi-user, cross-repo issue→PR automation harness. Owns the
deterministic plumbing (clones, branches, PRs, cleanup) so the
agent can focus on writing code. See `README.md` for the human pitch
and `ROADMAP.md` for milestone planning.

## Stack

Rails 8.1.3 · Ruby 3.2.3 · SQLite (dev/test) / MySQL (prod) ·
Solid Queue + Solid Cache + Solid Cable · Tailwind via
`tailwindcss-rails` · Turbo Streams + Stimulus · Octokit for GitHub.

## Architecture in 60 seconds

External polling drives everything — no webhooks. `PollAllRepositoriesJob`
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

`Job` carries the GitHub identifiers (issue + PR numbers, branch name).
`Workflow` is the top-level unit for a single attempt; it owns a chain of
`Step`s and a shared workspace at `$SYRUS_DATA_ROOT/workflows/<workflow_id>/`.
Each `Step` dispatches to a `Steps::` handler and owns one `Run`. `Run`
carries per-attempt state — prompt, agent metadata, diff, PR copy.

`Job#kind` is `issue` (default, filed from GitHub), `cron` (fired by a
`ScheduledTask` — no issue_number, prompt pre-rendered at fire time), or
`adhoc` (operator-created free-form prompt, no GitHub issue or scheduled
task — prompt supplied directly at job creation). All three kinds use the
same Workflow pipeline.

### Trigger kinds

`Workflow#trigger_kind` distinguishes what an attempt is *for*:

- `initial` — first attempt on a Job (issue → branch → PR)
- `pr_comment` — review feedback follow-up; reuses the same branch
- `ci_failure`, `retry`, `manual` — operator-initiated retries
- `rebase` — maintenance Run that rebases the PR's branch onto base
  when the PR has gone unmergeable. Skips the closed-Job guard (a
  preempted Job's external PR can still need rebases), skips
  `commit_agent_changes` (rebase rewrites history, not the working
  tree), uses `git push --force` instead of fast-forward, and skips
  the PR-opening step. Triggered by `PollAllRebasesJob` when a PR is
  `mergeable: false` and we control the head branch.
- `resume` — restores a prior Claude Code session. Chain:
  `agent_rebase → summarize_amend → push`. The session JSONL captured at
  end-of-session (stored in `ClaudeSession`) is copied back to the workspace
  at the project-encoded path; `--resume <session_id>` is passed to claude.
  Operator clicks "Resume" on any failed/cancelled Run that has a captured
  `ClaudeSession`.

### Per-Workflow pipeline (`app/jobs/run_job.rb`, `app/services/workflows/`, `app/services/steps/`)

Each Workflow runs a named chain of Steps. Workflow definitions live in
`app/services/workflows/`; step handlers in `app/services/steps/`. All Steps
in a Workflow share one `WorkflowWorkspace` (shallow clone at
`$SYRUS_DATA_ROOT/workflows/<workflow_id>/`). Workspace lifecycle is tied to
Workflow terminal transitions (not per-Step ensure). `WorkflowWorkspacePruneJob`
sweeps old terminal workspaces after 7 days.

Current chains:

```
initial:     prepare → implement → summarize → pr_open
pr_comment:  prepare → respond → summarize_amend → push
ci_failure:  prepare → analyze_and_fix → summarize_amend → push
retry:       prepare → implement → summarize → pr_open
rebase:      auto_rebase → force_push
resume:      agent_rebase → summarize_amend → push
```

Key steps:

- **`prepare`** — Runs `bundle install`, `npm ci`, etc. from `.syrus.yml`
  or auto-detects from lockfiles. Env is scrubbed to a safe forward list
  so the worker's Bundler config doesn't pollute the target repo's install.
  Per-command timeout: 10 minutes. Succeeds with "nothing to do" if the
  repo has no setup commands — chain shape stays uniform.
- **`implement`** / **`respond`** / **`analyze_and_fix`** — Agentic steps:
  invoke `AgentInvocation`, which spawns `claude --print` with `stream-json`.
  Pluggable `runner:` for tests.
- **`summarize`** / **`summarize_amend`** — Short agentic step that
  `--resume`s the prior session and asks the agent to call `submit_summary`.
  The session JSONL is on disk in the shared workspace — no DB roundtrip.
  If the implement step already called `submit_summary` (artifacts contain
  `agent_pr_title`), the summarize step skips the agent call entirely and
  promotes artifacts directly — saving a full agent turn.
- **`pr_open`** / **`push`** / **`auto_rebase`** / **`force_push`** —
  Non-agentic: run service code (`PullRequestOpener`, `git push`, etc.).

**MCP sidecar** — `bin/syrus-mcp-sidecar`, spawned by `claude` over stdio
via a per-step `mcp.json` tempfile. Exposes one tool,
`submit_summary(pr_title, pr_body, summary)`, which writes directly onto
the Workflow's `artifacts` bag and appends a `JobLog` audit line.
`alwaysLoad: true` in the mcp.json keeps sidecar tools in the agent's
active toolset even after `--resume`. The config key and binary basename
must match (`syrus-mcp-sidecar`) — misalignment causes the resumed agent
to invoke a tool name that doesn't exist. See `app/services/syrus_mcp/`.

**PR copy degradation** — `open_pull_request_if_missing` reads
`workflow.artifacts["pr_title"]`/`["pr_body"]` first; falls through to
`PrSummarizer`; falls through to a templated default. Path 1 is the goal.

**Diff capture** uses `git diff <default_branch>...HEAD` (three-dot — what
GitHub's "Files changed" tab shows) to avoid pollution when the base branch
moves forward while the syrus branch is open.

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
threshold; operator must Resume to re-enable.

"No changes" is the explicit happy path for cron Jobs — the agent
surveys, calls `submit_summary` with a one-line note, and the Job closes
with reason `no_changes`.

### Live UI

`Job` and `Run` use `broadcasts_refreshes` + Turbo morph (`<%= turbo_refreshes_with method: :morph %>`)
so the worker's DB writes update the operator's browser without a refresh.
Dev mode uses `solid_cable` (NOT `async`) so cross-process broadcasts work.
The transcript element on the show page uses `data-turbo-permanent` to
preserve scroll position across morphs.

## Conventions

- **Prompts** all live under `app/services/prompts/` as PORO classes
  (`Prompts::Initial`, `Prompts::PrFeedback`, `Prompts::PullRequestSummary`,
  `Prompts::SubmitSummaryInstructions`, `Prompts::Rebase`, `Prompts::Resume`,
  `Prompts::ScheduledTask`, `Prompts::AdhocJob`). Each has a `to_s`. Compose
  by appending; never inline prompt text in jobs/services.
- **Encrypted attributes** — `User#github_token`, `User#claude_oauth_token`
  use Active Record Encryption. Means `RAILS_MASTER_KEY` is required in
  any process that touches them. Smoke tests inside containers without
  the key will fail at User creation — by design.
- **AASM events on Run** — call `start!`, `succeed!`, `fail!`, `cancel!`,
  always followed by `save!` (callbacks set timestamps but don't persist).
  See `Run` model.
- **Per-Job concurrency** — `RunJob` uses Solid Queue's `limits_concurrency`
  keyed on `job_id` so two Workflows on the same Job never overlap. (Was
  per-repo; changed because the shared WorkflowWorkspace path is per-Workflow-id,
  so the collision risk is within a Job, not across repos.)
- **Two SolidQueue queues** — `runs` (dedicated worker) for long agent
  invocations; `default` for pollers, Turbo broadcasts, and reaper jobs.
  Splitting prevents long RunJobs from starving the reaper and making the UI
  feel frozen.
- **Per-user max-turns** — `User#agent_max_turns` (default 200, range
  0–1000). `0` means no `--max-turns` flag is passed to claude (the
  per-run 30-minute timeout still bounds runaway loops). Threaded through
  RunJob → AgentInvocation for both regular and rebase runs.
- **Per-user scheduling pause** — `User#scheduling_paused` (boolean).
  `PollScheduledTasksJob` skips paused users entirely. Operator can toggle
  via admin UI; user can toggle in `/credentials/edit`.
- **Per-Job priority** — `Job#priority` is `high` / `medium` (default) /
  `low`. Converted to SolidQueue integers at enqueue time via
  `Job#solid_queue_priority` (high→0, medium→10, low→20); the
  `Run#enqueue_run_job` path and paused-run re-enqueue in `RunJob` both
  use it. Admin API exposes `priority` on job list and detail responses.
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
- **Three-dot diffs only** — `git diff <base>...HEAD`, never two-dot.
  Lesson learned the hard way (commit `67b2bf9`).
- **Clones live outside the repo** — under `$SYRUS_DATA_ROOT` (default
  `~/.syrus`). The agent's `chdir` MUST NOT be inside the operator's
  checkout. (Lesson from commit `ced3a65`.)
- **Tests** — RSpec, no FactoryBot. Lightweight `Factories` module in
  `spec/support/`. WebMock + VCR for GitHub. The agent runner is stubbed
  via `RunJob.agent_runner` and `PrSummarizer.runner` test seams; never
  shell out to real `claude` from tests.
- **REST Admin API** — `GET /api/v1/admin/overview`, `/stuck`, `/jobs`
  (filterable by `pr_number`, `issue_number`, `repo`, `state`, `user`,
  `has_active_workflow`, `failed_in_last_24h`), `/jobs/:id`, `/workflows/:id`,
  `/runs` (cross-Job flat list; filterable by `state`, `trigger_kind`, `job_id`,
  `since`), `/queue`, etc. Bearer-token auth via `User#api_token`
  (deterministic-encrypted column). Nested serializers are resilient — a single
  bad row emits `{ error_serializing: "..." }` rather than 500ing the whole
  response (`Admin::JobStateSerializer`). See `app/controllers/api/` and
  `app/services/admin/`.

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

Syrus runs on the homelab K3s cluster and polls **`tkadauke/syrus-test`**
(private) as its dev sandbox. To exercise a change end-to-end, file
an issue on that repo with the `syrus` label — the deployed dev
Syrus picks it up and opens a PR there:

```
gh issue create -R tkadauke/syrus-test --label syrus \
  --title "..." --body "..."
```

Don't run `bin/dev` and stub things to simulate the agent — file a
real issue and watch the real flow. Test issues should be small
(single-PR scope), low-stakes, reversible, and describe real (if
frivolous) improvements — the agent actually implements them.

**Now the important part: be actually funny.** The model defaults
to a tepid productivity-blog register — bullet points, neutral verbs,
"considerations." For syrus-test issues, override that hard. The
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
private, the audience is future-you and the agent that picks it up.
Make it a good time. If the issue body reads like something you'd
actually post in a customer-facing tracker, you've under-reached.

## Debugging staging / production via kubectl

Two clusters: **staging** uses the default kubeconfig
(`~/.kube/config`), **production** lives at
`~/.kube/config-production`. Pick by passing `--kubeconfig` on every
call (or `export KUBECONFIG=...`).

```bash
# Default cluster = staging.
kubectl -n syrus-staging get pods
# Production:
kubectl --kubeconfig ~/.kube/config-production -n syrus-production get pods
```

**Pod label gotcha:** the pods are labelled `name=syrus-worker` /
`name=syrus-web`, NOT `app=...`. The selector that works:

```bash
POD=$(kubectl --kubeconfig ~/.kube/config-production -n syrus-production \
       get pods -l name=syrus-worker -o jsonpath='{.items[0].metadata.name}')
```

**Logs.** The container name is `syrus-worker` (with a `fix-perms`
init container — `kubectl logs` complains about "defaulted to" if
you don't pass `-c`). Worker logs are noisy with ActiveJob
serialization; grep for the bits you need:

```bash
kubectl --kubeconfig ~/.kube/config-production -n syrus-production \
  logs deployment/syrus-worker --tail=500 \
  | grep -E "PollAllRebases|PollRebaseJob|preempted|RunJob|FAIL"
```

**Rails console / runner.** Don't try to inline complex Ruby into
`bin/rails runner '...'` — kubectl's shell escaping mangles
backslashes inside string literals (`\1` regex backrefs, `\"` escapes
in dig calls, etc). Write the script to `/tmp/script.rb` locally,
`kubectl cp` it in, `bin/rails runner /tmp/script.rb`:

```bash
POD=$(kubectl --kubeconfig ~/.kube/config-production -n syrus-production \
       get pods -l name=syrus-worker -o jsonpath='{.items[0].metadata.name}')
kubectl --kubeconfig ~/.kube/config-production -n syrus-production \
  cp /tmp/diagnose.rb $POD:/tmp/diagnose.rb -c syrus-worker
kubectl --kubeconfig ~/.kube/config-production -n syrus-production \
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
worktrees and zombie Runs can accumulate. The orphan-sweep on next
setup (`5e325b0`) catches terminal Runs' worktrees, but Runs whose
state is stuck in `running` are cleaned up by `ReapStaleRunsJob`. If you see a
"refusing to fetch into branch X checked out at /worktrees/N" error
post-deploy, it's a stale registration — clean by walking
`<bare>/.git/worktrees/*` and force-removing whose Run is
terminal-or-zombie.

## Workflows

Local dev:

```
bin/setup          # initial install + DB
bin/dev            # foreman: web + worker + tailwind:watch
bin/rspec          # full suite (~10s, 230+ examples)
bin/rspec spec/jobs/run_job_spec.rb   # one file
```

Docker (production image):

```
docker build --platform linux/amd64 -t syrus:amd64 .
```

The image is single-purpose (worker pod overrides CMD to `["./bin/jobs"]`);
web pod uses the default `./bin/thrust ./bin/rails server`. See
"Deploy target" below for the amd64 / Apple Silicon gotcha.

Deploying to staging + production (K3s):

```
bin/deploy                # both clusters (default)
bin/deploy --staging      # staging only
bin/deploy --production   # production only
bin/deploy --skip-build   # assume :<sha> already pushed
```

Reads the GHCR PAT from `$GHCR_TOKEN` or
`~/.config/syrus/ghcr-token` (chmod 600). Builds linux/amd64,
pushes `ghcr.io/tkadauke/syrus:<sha>` + `:latest`, runs
`kubectl rollout restart` on `syrus-web` and `syrus-worker` in
both namespaces, waits for rollout status. Production uses
`~/.kube/config-production`; staging uses the default kubeconfig.

## Deploy target

K3s on the homelab cluster (Intel NUC 12 → **linux/amd64**). Build
images with `--platform linux/amd64`. On Apple Silicon, use Colima
with Rosetta and the `colima` (docker driver) buildx builder — NOT
the `multi` (docker-container) builder, which falls back to QEMU TCG
and turns 5-min builds into 15-min builds. The full Colima/Rosetta
playbook is in `~/code/greenacres/.claude/skills/colima-amd64-build/SKILL.md`.

Required runtime env:

- `RAILS_MASTER_KEY` — credentials decryption
- `SECRET_KEY_BASE` — sessions, signed cookies
- `DB_HOST`, `SYRUS_DATABASE_PASSWORD` — primary MySQL
- `SYRUS_DATA_ROOT` — defaults to `/home/rails/.syrus`. Mount a PVC
  here on worker pods so the bare-clone cache survives restarts.
  Web pods don't need this volume.

## Things that bit us (don't repeat)

- **`claude --mcp-config` is variadic.** It consumes positional args
  until the next flag, so it MUST be slotted between two flags — never
  immediately before the prompt. (Commit `d9d094e`.)
- **`broadcasts_refreshes_to ->(run) { run.job }`** breaks under
  Action Cable's `async` adapter in dev (single-process). Use
  `solid_cable` in dev (`config/cable.yml`).
- **`db:prepare` errors loudly** when only the primary DB is reachable
  — it tries cache/queue/cable too. The primary still migrates fine.
  Inside containers without all four MySQLs, `|| true` past the error.
- **`BUNDLE_WITHOUT="development"` doesn't exclude `:test`** — use
  `"development:test"` (colon-separated). The Rails 8 default is wrong.
  (Fixed in commit `77cae32`.)

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
app/services/syrus_mcp/sidecar.rb            # MCP::Server boot + SIGTERM trap
app/services/syrus_mcp/submit_summary_tool.rb # the one MCP tool (writes to Workflow#artifacts)
app/services/prompts/                        # all agent prompts (PORO)
app/services/pr_summarizer.rb                # second-shot fallback
app/jobs/poll_*.rb                           # polling jobs (cron-style; see config/recurring.yml)
app/jobs/reap_stale_runs_job.rb              # kills zombie Runs every minute
app/jobs/workflow_workspace_prune_job.rb     # daily sweep of old terminal workspaces
app/jobs/claude_session_prune_job.rb         # drops old ClaudeSession rows daily
app/models/{job,run,workflow,step}.rb        # core models + AASM
app/models/{repository,user}.rb             # repo + user (user has api_token, cron_templates)
app/models/scheduled_task.rb                 # cron/one-shot task attached to a repo
app/models/cron_template.rb                 # per-user reusable schedule+prompt template
app/models/claude_session.rb                 # captured JSONL for --resume flows
app/controllers/api/                         # REST admin API (Bearer-token auth)
bin/syrus-mcp-sidecar                        # Ruby binstub, claude spawns this
bin/jobs                                     # Solid Queue worker entry
config/database.yml                          # 4-DB prod (primary/cache/queue/cable)
config/queue.yml                             # SolidQueue: `runs` + `default` worker split
config/recurring.yml                         # Solid Queue recurring job schedule
ROADMAP.md                                   # milestone plan + future work
```
