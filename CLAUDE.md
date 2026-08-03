# Syrus — agent guide

A multi-user, cross-repo issue→PR automation harness. Owns the
deterministic plumbing (clones, branches, PRs, cleanup) so the
agent can focus on writing code. See `README.md` for the human pitch
and `ROADMAP.md` for milestone planning.

## Stack

Rails 8.1.3 · Ruby 3.4.10 · SQLite (dev/test) / MySQL (prod) ·
Solid Queue + Solid Cache + Solid Cable · React + TypeScript via Vite ·
TanStack Query · Tailwind via `tailwindcss-rails` · Go CLI under `cli/` ·
Octokit for GitHub.

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
Job (one per issue):       open ⇄ closed; no_change_needed (semi-terminal)
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
  the head branch. Closed-preempted Jobs stay in this poll scope only
  while their tracked external PR is open; once that PR merges or closes,
  `PollMergeStateJob` finalizes them as `external_pr_merged` /
  `external_pr_closed`.
- `stack_rebase` — maintenance Run that rebases a dependent PR stack
  branch-by-branch, force-pushes each updated branch, then resumes
  landing for approved stack Jobs.
- `coding_handoff` — triggered after a coding-mode chat session commits
  and hands off via `complete_implement_step` (existing Job) or
  `submit_coding_changes` (creates a new direct Job); requires operator
  confirmation before dispatching. On grader pass, opens the PR and
  notifies the linked chat. On grader failure, reverts the Job to `:coding`
  so the agent can fix and re-run.

### Per-Workflow pipeline (`app/jobs/run_job.rb`, `app/services/workflows/`, `app/services/steps/`)

Each Workflow runs a named chain of Steps. Workflow definitions live in
`app/services/workflows/`; step handlers in `app/services/steps/`. All Steps
in a Workflow share one `WorkflowWorkspace` (shallow clone at
`$SYRUS_DATA_ROOT/workflows/<workflow_id>/`). Workspace lifecycle is tied to
Workflow terminal transitions (not per-Step ensure). `WorkflowWorkspacePruneJob`
sweeps old terminal workspaces after 7 days.

Current chains:

```
initial:     prepare → [loop(implement → adversarial_review)] → retry_until(implement → graders) → coverage_analyze → summarize → test_plan → pr_open
pr_comment:  prepare → [loop(respond → adversarial_review)] → retry_until(respond → graders) → coverage_analyze → coverage_pr_comment → summarize_amend → refresh_job_metadata → try(push)
chat_feedback: prepare → [loop(respond → adversarial_review)] → retry_until(respond → graders) → coverage_analyze → coverage_pr_comment → summarize_amend → refresh_job_metadata → try(push)
ci_failure:  prepare → analyze_and_fix → summarize_amend → try(push)
retry:       prepare → [loop(implement → adversarial_review)] → retry_until(implement → graders) → coverage_analyze → summarize → test_plan → pr_open
rebase:      auto_rebase → agent_rebase → force_push
stack_rebase: stack_auto_rebase → stack_agent_rebase → stack_force_push
auto_merge:  mergeability_preflight → prepare → retry_until(graders, repair: landing_fix) → push → auto_merge
merge_train: merge_train_assemble → merge_train_build → prepare → retry_until(graders, repair: landing_fix) → merge_train_land
coding_handoff: prepare → grader_fanout → grader_collect → summarize → test_plan → pr_open
```

`[loop(...)]` steps are conditional: the `adversarial_review` loop only appears when `adversarial_review_rounds > 0` (per `.syrus.yml` or `AppSetting`); `coverage_analyze` only appears when a coverage plan is configured for the repository.

Key steps:

- **`prepare`** — Runs `bundle install`, `npm ci`, etc. from `.syrus.yml`
  or auto-detects from lockfiles. Env is scrubbed to a safe forward list
  so the worker's Bundler config doesn't pollute the target repo's install.
  Per-command timeout: 10 minutes. Succeeds with "nothing to do" if the
  repo has no setup commands — chain shape stays uniform. **Failure mode
  depends on the command's source** (`RepoPrepPlan::Result#guessed?`):
  explicit `.syrus.yml` commands hard-fail (raise `StepFailed`, abort the
  chain before the agent), but auto-detected (guessed) commands soft-fail —
  Syrus logs a non-fatal warning, records `prepare_failure` with
  `"soft" => true`, and hands off to the agent anyway. This stops a wrong
  lockfile guess (stale lock, build-script gate, unused tool) from wedging
  onboarding: the first Job on a repo can still run and add a `.syrus.yml`.
  `Repository#prepare_enabled` can disable the step for all workflows on
  that repo; the `syrus-skip-prepare` issue label disables it for that Job.
  Skips are recorded in Workflow artifacts and logged on the first Run.
  `.syrus.yml` can also contain `hooks.post_checkout`, but those commands
  are for the local `syrus checkout` CLI on the operator's machine after a
  branch checkout. They do not run in the agent sandbox and are not a
  substitute for `prepare`.
- **`implement`** / **`respond`** / **`analyze_and_fix`** — Agentic steps:
  invoke the Workflow's configured `AgentProviders::*` adapter. Claude uses
  `AgentInvocation`/`claude --print`; Codex uses `CodexInvocation`/`codex exec`.
  Pluggable `runner:` for tests.
- **`auto_rebase`** / **`agent_rebase`** / **`force_push`** — Rebase chain:
  first try deterministic `git rebase`; if clean, cancel only `agent_rebase`
  and still `force_push`. On conflict, `agent_rebase` resolves it, then
  `force_push` updates the PR branch with an explicit `--force-with-lease`
  against the branch SHA Syrus observed.
- **`push`** / **`push_agent_rebase`** / **`push_after_rebase`** — Follow-up
  push chain for feedback and CI repair. `push` first attempts a normal
  update; on a non-fast-forward rejection it fetches the current PR branch,
  tries a deterministic rebase, and retries the push if clean. If that rebase
  conflicts, the declared `try(push)` branch dynamically inserts
  `push_agent_rebase`, a check-first grade loop repaired by `landing_fix`, and
  `push_after_rebase`. The inserted Steps are normal Step rows, so a later
  failure can use retry-from-failed-step.
- **`grader_fanout`** / **`grader`** / **`grader_collect`** — Read grader
  commands from `.syrus.yml`, materialize one immutable `grader` Step per
  configured grader, and aggregate required failures. `Workflows::RetryUntil`
  appends bounded repair/check iterations using `AppSetting.grade_max_iterations`.
  Graders support an optional `when_files_changed` array of glob patterns; at
  fanout time Syrus computes changed files via `git diff --name-only <base>...HEAD`
  and skips any grader whose patterns don't match — useful for expensive checks
  like website builds that only matter when relevant files changed. Landing
  workflows may dispatch multiple grader Runs from the fanout in parallel,
  capped within the landing unit; `grader_collect` waits for every required
  result before deciding whether repair is needed.
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
  ancestor), not by rebase-internal refs like `REBASE_HEAD`; build fetches
  base/member refs through the repository's authenticated GitHub URL so private
  branches work under App or PAT credentials; land pushes the integration
  branch, merges one integration PR into base, then comments on and closes the
  member PRs.
- **`adversarial_review`** — Independent critic agent that reads the issue
  and the diff from the preceding `implement` (or `respond`) step, then calls
  `submit_adversarial_review(verdict, critique)`. Verdict `approved` exits the
  loop (findings carry forward but no re-implement needed); `needs_work` feeds
  findings back to the next `implement`/`respond` iteration via `prior_findings`
  in the prompt. The reviewer's workspace changes are discarded — it is
  read-only. Runs in feedback workflows (`pr_comment`, `chat_feedback`) as
  well as `initial`/`retry`; skipped in `ci_failure`, `auto_merge`, and
  maintenance workflows. `.syrus.yml` accepts an optional `criteria` array in
  the `adversarial_review` block to inject repository-specific checklist items
  into the reviewer prompt (additive — the default checklist still runs).
- **`summarize`** / **`summarize_amend`** — Short agentic step that
  asks the agent to call `submit_summary`.
  If the upstream agentic step (`implement` for `summarize`; `respond` or
  `analyze_and_fix` for `summarize_amend`) already called `submit_summary`
  (the run has `agent_pr_title` set), the step skips the agent call entirely
  and promotes artifacts directly — saving a full agent turn and avoiding
  failures when the MCP sidecar is slow to connect.
- **`test_plan`** — Short agentic step in the initial Workflow after
  `summarize`. It asks the agent to call `submit_test_plan` with concise
  reviewer-facing checks; `pr_open` appends them as a Test Plan section
  headed by a copy-pasteable `syrus checkout JOB-<id>` command.
  If the `implement` step already called `submit_test_plan` (the
  `test_plan` workflow artifact is already populated), the step skips
  the agent call entirely.
- **`refresh_job_metadata`** — Agentic step after successful `pr_comment` and
  `chat_feedback` workflows. It asks the agent to call `submit_job_metadata`
  only when feedback changed the Job's effective intent; otherwise the agent
  reports `changed=false`. The following `push` step applies changed metadata
  to direct Job titles, managed PR title/body, Job detail copy, and search
  indexing.
- **`pr_open`** —
  Non-agentic: run service code (`PullRequestOpener`) to push the branch and
  open the PR if needed.

**MCP sidecar** — `bin/syrus-mcp-sidecar`, spawned by `claude` over stdio
via a per-step `mcp.json` tempfile. Tools available to workflow agents:
`read_live_state(detail)` — read-only Job/Workflow/Run/queue snapshot;
`read_memory`, `write_memory`, `delete_memory`, `search_memories`,
`list_memories` — repository-scoped `ChatMemory` access (writes stamp
`author: agent`, `source_type: run`);
`get_coverage_report` — coverage summary for the current run;
`read_run_worker_health(run_id:)` — retained worker CPU/memory/disk/pressure
samples correlated with a Run, including grader command spans when recorded;
treat process command details from this tool as potentially sensitive and
summarize rather than pasting raw tokens or auth-bearing commands;
`read_performance_diagnostics` — sanitized current/all-revision performance
summaries, available only to implement agents working on `tkadauke/syrus` or a
registered fork;
`submit_summary(pr_title, pr_body, summary)` and
`submit_test_plan(steps, notes)` — write to Workflow `artifacts` and append
`JobLog` audit lines;
`submit_job_metadata(changed:, ...)` — used only by `refresh_job_metadata`;
`submit_adversarial_review(verdict, critique)` — used by the `adversarial_review` step;
`report_main_concern(failing_tests, reason)` — flag broken-main suspicion.
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

### Terminal feature

Interactive terminal access is a labs feature and is off by default. Enable it
with:

```ruby
Feature.find_by(slug: 'terminal').update(enabled: true)
```

Worker-side terminal sessions advertise their TCP relay with
`SYRUS_TERMINAL_HOST`. Bare-metal/local development can leave it blank and
`TerminalRelay` falls back to `127.0.0.1`. Docker Compose sets it to the
worker service name (`worker`) so the web container can connect through Docker
internal DNS. Kubernetes worker pods should set both `MY_POD_IP` and
`SYRUS_TERMINAL_HOST` from the Downward API field
`status.podIP`; the web pod reads each session's `relay_address` from the DB
and connects directly over the CNI network. Traefik is not involved.

Terminal sessions survive browser navigation because the PTY lives in the
worker-side session until it exits or the user kills it. Sessions die on worker
restart/deploy; there is no wall-clock idle timeout. The security boundary is a
per-session auth token exchanged over the relay socket after the browser's
authenticated Action Cable subscription is authorized, and the relay is not
exposed through public ingress or Traefik.

**Closed PR resolution** does not blindly treat every closed PR as
`pr_closed`: merged PRs close as `pr_merged`, and closed unmerged PRs whose
branch has no unique patches left against the PR base close as `no_changes`.
`no_changes` is a successful parent resolution for dependency gates, stack
rebases, and landing queue wakeups.

**Failure resilience** — failed Runs persist a `RunFailureClassification`
from diagnostics, recent logs, spawned process outcomes, and agent outcome.
`AutoRetryScheduler` may retry transient failures up to three times with
5m/20m/1h backoff, either from the failed Step while the workspace remains
or as a fresh retry Workflow. Failed agentic runs with captured sessions can
resume from the failed Step instead of starting over. `ProviderCircuitBreaker`
suppresses automatic retries/CI repair during provider-wide transient outages.
`ReapStaleRunsJob` also repairs worker-death gaps: re-enqueues queued Runs
whose inline driver disappeared, cancels impossible queued Steps whose Runs
are all terminal, and finishes running Workflows once every Step/Run is
terminal.

### Scheduled tasks

`ScheduledTask` lets the operator attach recurring or one-shot agent
prompts to a repository — no GitHub issue required. `kind=cron` uses a
5-field cron expression (validated to fire at most once per hour);
`kind=one_shot` uses a `fire_at` datetime. Cron tasks honor the entered
minute exactly and are evaluated in UTC hourly windows so repeated poller
ticks do not double-fire the same hour. Tasks can optionally reference a
`CronTemplate` (`app/models/cron_template.rb`) — a per-user reusable
prompt+schedule config that multiple ScheduledTasks can share. Applying a
template copies its values into the task; later template edits do not rewrite
existing tasks.

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
surveys, calls `submit_summary` with a one-line note, and exits without
committing anything. The Job lands in `no_change_needed` (a semi-terminal
state); the operator can Close it (work already done) or Give Feedback
(agent may have missed something). Retry actions are suppressed for this
state.

### Instance mode

`AppSetting#mode` is `"advanced"` by default and can be switched to
`"simple"` from Admin Settings. Simple mode is a non-technical operator
experience: Coding Mode and Local Mode are force-disabled, developer surfaces
like Jobs/Workflows/scheduled tasks/GitHub Issues are hidden from the UI,
Epics are presented as features, and child Jobs under Epics are expected to
form a strict linear chain. Simple-mode Epic child Jobs auto-land after
passing graders, then the Epic becomes feature-reviewable; feedback appends a
new direct Job at the end of the chain. Implement, PR-feedback, and CI-repair
prompts include `Prompts::SimpleModeAgentContext`, so agents should make
technical defaults, ask at most one focused clarifying question only for
genuine ambiguity, write tests, and finish the scoped task without TODO
handoffs.

### Live UI

Authenticated operator pages are React routes rendered by
`app/views/spa/show.html.erb` and backed by `/api/v1/app/*` JSON
controllers. React uses TanStack Query for server state and
`AppUserChannel` app events for live invalidation or compact payload
updates, notably chat message tails, queued chat messages, controls,
and whiteboard changes.

Chat turns run in persistent chat workspaces, not repository workflow
workspaces. In normal planning sessions, attached repository checkouts
are read-only to agents; chat can inspect code and queue/propose Jobs,
Epics, or issues. In **Coding Mode** (labs feature `coding_mode`), the
chat workspace gets a writable full clone on a dedicated branch so the
agent can implement directly. `ChatWorkspacePrepareJob` auto-installs
dependencies after every coding checkout (`:chat` queue, same soft-fail
semantics as the workflow `prepare` step), and agents can inspect the checkout
prep state before assuming dependencies are ready. Chat has a
`reset_workspace` MCP tool that is status-only by default and requires
`confirm_discard: true` before it discards dirty or ahead-of-default Coding
Mode work and prepares a fresh branch. After committing, the agent
calls `complete_implement_step` (to hand off an existing Job) or
`submit_coding_changes` (to create a new direct Job from the branch) —
both create a pending action that requires operator confirmation before
the `coding_handoff` Workflow is dispatched. While a chat turn is busy,
follow-up user messages are stored as `ChatQueuedMessage`s and delivered
sequentially after the current turn finishes.

Supervisor chat is a feature-gated admin control room
(`admin_supervisor_chat`). It is one pinned, durable chat per admin with no
repository attachment by default. `SupervisorEvents.publish!` records scoped
operational events for Supervisor chats and for ordinary chats that originated
the referenced work; a disposable `ChatScopedEventEvaluatorJob` reviews each
event with read-only tools and either records `no_op` or creates a real
`ChatWakeup` (`respond`/`act`). Supervisor prompts tell agents to read current
Syrus state before acting on event payloads and to keep risky side effects
behind proposals or pending-action confirmation.

Chat proposal tools can express runtime dependencies when drafting work:
`depends_on` for Job proposal slugs in the same chat, `depends_on_job_ids` for
existing Jobs, `depends_on_epic_ids` for existing Epics, and
`depends_on_proposal_slugs` for Epic proposal ordering. Chat also has
`add_job_dependency` / `remove_job_dependency` MCP tools to adjust manual Job
dependencies after Jobs exist. Proposal materialization validates dependency
targets up front; invalid same-chat slugs or inaccessible existing IDs should
be fixed in the proposal instead of relying on filing order.

Dev and prod use `solid_cable` (NOT `async`) so browser app events work
across web/worker processes.

Chat composer input follows chat-app conventions: pasting a file (image,
PDF) into the composer attaches it through the same funnel as the picker
and drag-in (`handlePaste` → `handleAttachmentChange` in Chat.tsx), so
validation, the walkthrough-video split, and the one-at-a-time guard all
apply. The `chat_polish` UI-experiment Feature (default off) adds subtle
motion-safe chat animations (new-message entrance, smooth jump-to-bottom).

**Walkthrough videos (video → Epic)** — a labs feature behind the
`video_walkthroughs` Feature flag (default OFF; declared in
`config/features.yml`, toggled in the app's Features tab). When the flag is
off: the composer hides recording/video intake (`payload.walkthroughs_enabled`),
the upload/retry endpoints 404, `VideoWalkthroughAnalysisJob` fails the row
terminally, `ChatTurnJob` skips walkthrough orientation, and the three
walkthrough MCP tools vanish from the sidecar's advertised set
(`Sidecar::WALKTHROUGH_TOOLS`) — while already-analyzed threads keep their
history (media panel + message cards render read-only) and
`VideoWalkthroughPruneJob` keeps enforcing retention. When ON — chats accept
narrated screen
recordings (composer `+ → Record a walkthrough`, drag-in, or file picker;
webm/mp4/mov, ≤15 min, ≤500 MB). `ChatVideoWalkthrough` (Active Storage)
uploads via multipart `POST /api/v1/app/chats/:chat_id/video_walkthroughs`;
`VideoWalkthroughAnalysisJob` (queue `videos`, low-concurrency) runs Gemini —
Files API resumable upload → poll ACTIVE → one `generateContent` with a JSON
`responseSchema` (`Prompts::VideoWalkthroughAnalysis`) at FULL
`media_resolution` (LOW measurably garbles small on-screen text; the job
retries at LOW only if a ≥12-min video's full-res attempt is actually
rate-limited — graceful degradation, `Gemini::Client::LOW_RESOLUTION_FALLBACK_SECONDS`).
The schema is engineered for Flash's strengths: a timestamped `transcript`
FIRST (Flash is excellent at ASR; it anchors the rest and curbs hallucination),
then `sections` (topical ranges — the handles for later "zoom in"), then
`issues` grounded in `transcript_evidence` (the user's quoted words),
`visual_evidence`, `severity` (low/medium/high), `surface`, `user_flagged` (the
user circled/underlined with a red pen or said "here"/"this"), and
`needs_closer_look`. **OCR handoff (Gemini flags, Claude reads)** — Gemini
Flash canNOT reliably OCR small on-screen text (error codes, IDs, URLs, config
values, stack traces, precise numbers) from VIDEO at any resolution, but Claude
reads that same text perfectly off a STILL frame. So the analysis prompt tells
Gemini NOT to guess such text: it sets `needs_closer_look=true` and describes
what/where in a new optional `unreadable_text` field instead of fabricating a
value. The chat agent then pulls a crisp still itself (via `get_walkthrough_analysis`
or `read_walkthrough_frame`, below) and `Prompts::VideoWalkthroughReport` steers it
to READ the exact characters off the screenshot and never invent one it can't
read. Flagged issues (`needs_closer_look` or a non-empty `unreadable_text`) are
captured at top OCR-grade `HIGH_JPEG_QUALITY` and prioritized to survive the
per-response `MAX_FRAMES` cap. **Segment "zoom in"** — the Gemini Files API retains the
upload ~48h, so `Gemini::Client#analyze_segment` re-analyzes a CLIP of the SAME
file at full resolution with no re-upload (a `video_metadata` `{ start_offset:
"12s", end_offset: "30s" }` sibling of `file_data`). The chat MCP tool
`analyze_walkthrough_segment(walkthrough_id, start, end, focus)`
(`SyrusChatMcp::AnalyzeWalkthroughSegmentTool`, deferred, `Prompts::VideoWalkthroughSegment`)
lets the chat agent get finer detail (exact error text, click sequence) on
`needs_closer_look` moments or on request; it re-uploads the stored blob when
the file is past retention, and reports "video expired" only when the blob is
also pruned. Test seam `AnalyzeWalkthroughSegmentTool.client_factory`.
**On-demand still (`read_walkthrough_frame`, deferred)** —
`SyrusChatMcp::ReadWalkthroughFrameTool` lets the chat agent pull a crisp
screenshot from the stored video at ANY timestamp (beyond the ones
`get_walkthrough_analysis` returns) so it can OCR a moment it decides matters. It runs `Gemini::FrameExtractor`
locally (no Gemini call/key needed), clamps the timestamp to the video, and
maps a pruned/unreadable blob to a clean "video expired" error. **Delivery: the
frame comes back as a native MCP `image` content block** — the MCP server
serializes the tool `Response`'s content array verbatim onto the wire, and
Claude Code (`claude --print`) renders an `{ type: "image", data, mimeType }`
block into the agent's context as an actual image it sees THIS turn. That is the
only channel that puts a picture in front of the chat agent mid-turn: there is
no `--image` CLI flag (see `ClaudeInvocation`), and the disk-file + Read-tool
path used for pasted attachments only reaches the NEXT turn. Helper
`SyrusChatMcp.image_result(jpeg:, text:)`. 720p (the compact stored blob) is
enough for Claude to OCR, so this tool extracts at the default width.
The job downloads the video once locally and runs the media flow off it: Gemini
analysis (oriented to the repo — slug + pinned chat context — and guardrailed
against inventing user-flagged issues when narration is silent and no mark is
visible) → `Gemini::VideoTranscoder` transcodes the source to a compact 720p mp4
that REPLACES the stored blob (empirically Gemini analyzes the compact mp4 as
well as the original — the narration carries the context — best-effort, keeps the
original on failure).
**First-class handoff (NOT a spoofed user message):** the job then posts the
VIDEO itself as a chat message (`video_walkthrough_id` + the operator's note),
shown in the thread as a walkthrough card and in the media panel. `ChatTurnJob`
detects that message and orients the agent with the SHORT
`Prompts::VideoWalkthroughContext` (names the tools, does not dump the analysis);
the agent then calls `get_walkthrough_analysis` (returns the report +
on-demand crisp stills as MCP image blocks) and works autonomously toward an Epic
— every step a real `tool_use`/`tool_result` chat event you can trace. Gemini is
the eyes, the chat agent stays the brain. Auth is an AI Studio API key only
(`User#gemini_api_key`, encrypted; validated via free `models.list` —
`CredentialProbe.gemini_key`, model resolved at analysis time by
`Gemini::Client#resolve_video_model!` against `VIDEO_MODELS`): the gemini-cli
OAuth path has no Files API and reusing its OAuth client violates Google ToS.
Videos are Active Storage blobs on Disk/S3 (NOT inlined in SQLite — only the
metadata row is). `VideoWalkthroughPruneJob` (daily) enforces both a time
ceiling (`AppSetting.video_retention_days`, default 7) and an instance-wide
size budget (`AppSetting.video_storage_budget_bytes`, LRU eviction, default
2 GB, 0 = unlimited) on the stored video blobs — the analysis + screenshots
always persist. Test seams: `VideoWalkthroughAnalysisJob.client_factory`,
`CredentialProbe.gemini_client_factory`, `Gemini::FrameExtractor.runner`,
`Gemini::VideoTranscoder.runner`.
Progress streams as `video_walkthrough.*` app events. **Desktop capture**:
`screenCapture.ts` FORCES full-screen capture (`useSystemPicker: false`, the
cursor's display) so the red-pen annotation overlay is always recorded — a
single window/tab would exclude it. It also grants the renderer's media
permissions and pre-warms the mic (paired with the `com.apple.security.device.audio-input`
entitlement + `NSMicrophoneUsageDescription`), without which macOS handed
`getUserMedia` a SILENT track and narration was lost. The recording controls
live in a separate always-on-top DRAGGABLE window (`recorderHud.ts`, content-
protected so it's excluded from the capture). The HUD panel is RECTANGULAR
(rounded corners composite with artifacts on a transparent always-on-top
window) and the window is sized to its content: the renderer measures the
panel after every render and reports it over `recorderHud:resize`
(`ipcRenderer.send` on the HUD's own preload — not scanned by the invoke-based
IPC parity spec), so no locale's hint can truncate. The HUD also carries a
mouse-only pen toggle button: main intercepts the `"pen"` action and flips the
overlay's pointer capture directly (`AnnotationController#toggleDraw`), a
zero-keyboard fallback that works regardless of uiohook or Accessibility
state; pen-armed sessions always get the auto-release watchers. **Red pen**:
`annotationOverlay.ts` does true HOLD-to-draw via a native global-key hook
(`globalKeyHook.ts`, uiohook-napi — N-API, all-arch prebuilds, asar-unpacked;
fails soft to the tap-to-arm shortcut when the module or macOS Accessibility
permission is unavailable — but never silently: every degrade point logs to
console + `<userData>/hold-to-draw.log`, a failed require is NOT cached so the
next recording retries, and disable() re-opens the once-per-recording
Accessibility prompt gate so granting the permission mid-session upgrades the
NEXT recording without a relaunch). enable() reports `{ available, hold,
reason? }` — reason (`no-module` / `no-accessibility` / `start-failed`) drives
the HUD hint, which nudges "allow Accessibility for hold" when that's the
actual obstacle; a repeat enable() on a live overlay re-derives `hold` from
the live hook and retries a dead hook instead of parroting a stale mode.

## Conventions

- **Public website/docs stay current.** Product-facing behavior changes
  must update `website/` in the same PR. If a change affects what Syrus
  is, why someone would use it, how to get started, a workflow, a feature,
  configuration, credentials, operations, schedules, chats/direct Jobs,
  troubleshooting, or an API surface, update the matching page under
  `website/src/site-pages/` or `website/src/content/docs/`. Prefer updating an
  existing page over adding a parallel one; if the navigation contract
  changes, update `website/README.md` too. PRs that add product behavior
  while leaving the public docs stale are incomplete.
- **Feature documentation is mandatory.** When adding or changing any
  operator-facing feature — configuration keys, feature flags, `AppSetting`
  columns, new step kinds, new trigger kinds, or changes to existing behavior
  — update the matching file under `config/syrus_docs/` in the same PR. New
  features that have no existing doc file should create one following the
  format in the existing files. PRs that add operator-facing behavior while
  leaving the docs stale are incomplete, same as public website docs.
- **Prompts** all live under `app/services/prompts/` as PORO classes
  (`Prompts::Initial`, `Prompts::PrFeedback`, `Prompts::CiFailure`,
  `Prompts::AdversarialReview`, `Prompts::PullRequestSummary`,
  `Prompts::SubmitSummaryInstructions`, `Prompts::TestPlan`,
  `Prompts::Rebase`, `Prompts::PushRebase`, `Prompts::LandingFix`,
  `Prompts::ScheduledTask`, `Prompts::DirectJob`, `Prompts::EpicContext`,
  `Prompts::VideoWalkthroughAnalysis`, `Prompts::VideoWalkthroughContext`,
  `Prompts::VideoWalkthroughReport`, `Prompts::VideoWalkthroughSegment`).
  Each has a `to_s`. Compose by appending; never inline prompt text in
  jobs/services. Epic-aware prompts append `Prompts::EpicContext` as
  orientation only; it must not expand the current Job's implementation scope.
- **Website/docs audit.** If no website/docs update is needed, the PR body
  must say why so reviewers can audit the call. `AGENTS.md` is a symlink to
  `CLAUDE.md`; preserve that relationship and edit the shared guidance through
  `CLAUDE.md`.
- **Feature flag descriptions are timeless.** `config/features.yml`
  descriptions must not reference PR numbers, issue numbers, or phrases like
  "Introduced in PR #123." or "Added in #456." That information is in git
  history; in the YAML it becomes stale and misleading once the flag is widely
  deployed. Describe only what the flag does and any operator requirements
  (e.g. "Requires a Gemini API key.").
- **SPA routes must be registered in Rails and React together.** Every path
  declared in `app/frontend/routes/App.tsx` (and any nested route file it
  references) needs a matching `get "...", to: "spa#show"` entry in
  `config/routes.rb`. Without it, a browser hard-reload or direct navigation
  to that URL returns "No route matches ..." from Rails instead of serving the
  SPA shell. The `app-shell/*path` wildcard only covers `/app-shell/`-prefixed
  paths; all other routes require an explicit entry. When adding a new React
  route, add the Rails counterpart in the same PR. Reviewers should check both
  files.
- **Frontend i18n** — all user-visible strings in the SPA use i18next. Use the
  `useT` hook (`app/frontend/hooks/useT.ts`, a re-export of `useTranslation`) and
  pick the right namespace (`common`, `nav`, `jobs`, `epics`, `dashboard`, `chat`,
  `settings`, `admin`). Locale files live under
  `app/frontend/i18n/locales/{en,de,la}/`. When adding new strings, add them to
  all three locales. Backend: `User#locale` drives `I18n.locale` per request via
  `ApplicationController#switch_locale`; `User::LOCALES` is the source of truth
  for valid values.
- **Go CLI** lives under `cli/` and talks to the app-scoped JSON API
  (`/api/v1/app/*`). Keep CLI commands, API serializers/controllers, and
  `website/src/content/docs/api.md` aligned when changing terminal-visible
  behavior; test CLI changes with `go test ./...` from `cli/`. The CLI covers
  chat plus Job, Epic, repository, schedule, checkout, inbox, test-plan,
  approval, and identity workflows; repo-aware commands should detect `origin`,
  scope to that repo by default, and refuse checkout changes when the local repo
  mismatches. Job and Epic identifiers are accepted as numeric IDs, `JOB-N`/`EPIC-N`
  prefixes, or human-readable slugs; use the `JobEpicRefFinder` concern
  (included in both app and admin base controllers) to resolve them server-side.
- **Desktop app** lives under `desktop/` as a separate Electron + React + Vite
  app. It uses Tailwind too, but it does not share the Rails web app's compiled
  CSS or components at runtime. Keep the desktop UI visually aligned with the
  web app's primitives: compact rows, restrained icon buttons, bordered white
  panels, terracotta primary actions (the brand accent, `#b6492e` at 600 —
  see the palette note below), emerald success pills, red failure/error
  pills, and slate/gray neutral text. Avoid broad element styling in
  `desktop/src/styles.css` (especially global `button` rules) because the tray
  surface relies on small, explicit controls. Prefer explicit local primitives
  such as `primary-button`, `secondary-button`, `icon-button`, and status pills.
  Ships on macOS (universal arm64+x64 DMG) and Windows (x64-only installer;
  Windows on ARM runs via built-in x64 emulation). Test desktop changes with
  `npm --prefix desktop run typecheck`, `npm --prefix desktop run build:renderer`,
  and `npm --prefix desktop run build:main`; run the desktop RSpec startup spec
  when Electron main/preload code changes. Local backend updates stream their
  progress over the existing shell-notice bridge: `updateBackend` parses the
  installer's `--json` NDJSON into `ShellNoticeState.backendUpdate` (phase
  `starting`/`downloading`/`migrating` + pull percent + `outage`), bounded by
  a 30-minute deadline that kills a wedged installer tree; the SPA renders it
  as a sidebar notice for the whole update, and `useBackendOutage` (in
  `useBackendUpdate.ts`, with a 5-minute staleness fuse) is the SPA's single
  choke point for "the backend is deliberately unreachable" — surfaces that
  read failed connectivity/credential checks must gate on it instead of
  rendering the unconfigured default ("GitHub not connected"). `outage` is
  true only from container recreation (`stack_up`) on; during the image pull
  the old backend still serves and nothing is gated.
- **Brand palette (terracotta).** The product accent is the terracotta of the
  winged-stylus brand mark (`#b6492e` at 600). `config/tailwind.config.js`
  defines the `terracotta` scale and remaps Tailwind's `blue` scale onto the
  same values, so legacy `*-blue-*` utilities render the brand accent without
  a repo-wide rename; prefer `terracotta-*` in new code. The desktop app
  mirrors the identical values in the `@theme` block at the top of
  `desktop/src/styles.css` — keep the two in sync (guarded by
  `spec/desktop/brand_palette_spec.rb`). Don't reintroduce raw blue hexes for
  accents; semantically-blue user choices (annotation pen colors, tag label
  colors) are the exception and stay blue.
- **Spending insights** live at `/insights/spending` and roll up `Run#cost_usd`
  plus `ChatSession#cumulative_cost_usd` by date window, Epic, user,
  repository, trigger kind, agent provider, trend, and top Runs. Non-admins
  only see their own spend; admins see instance-wide totals. Keep
  cost/accounting changes aligned with `App::SpendingPayload`,
  `docs/current-user-scopes.md`, and public docs.
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
- **Single-host Docker distribution** — `install.sh --docker` pulls
  `ghcr.io/tkadauke/syrus-backend` and starts the Compose stack; `bin/compose-up`
  builds the same stack locally. Keep `compose.env.example`, `.env.example`,
  and bootstrap payload expectations in sync when adding required env. Never
  regenerate `.env` over an existing `syrus_syrus-data` volume — those
  Active Record encryption keys must match the persisted DB. Test image-level
  changes with `bin/test-docker`; publish only through `bin/publish-image`,
  which builds, runs that integration gate, then pushes. Docker image scripts
  share common build/login/cache helpers in `bin/docker-image-lib`; extend that
  helper instead of copying Dockerfile target, GHCR login, pushed-manifest
  validation, Docker/GHCR plumbing, or registry cache logic between
  `bin/deploy`, `bin/publish-image`, and `bin/compose-up`.
  `SYRUS_DOCKER_REGISTRY_CACHE=1` opts local compose/publish builds into the
  registry BuildKit cache, and `SYRUS_DOCKER_CACHE_REF` overrides the cache tag.
  For desktop-app iteration against unpublished backend changes, `bin/build-local-image`
  builds `syrus-backend:dev-<sha>` from the working tree; stage it into the DMG
  with `SYRUS_BACKEND_IMAGE=<ref> npm --prefix desktop run build`. The
  registry is selected by data, not code: manifest.json carries the
  fully-qualified ref, install.sh pulls it verbatim, release builds pin
  `ghcr.io/tkadauke/...`. Local-only tags survive only until Docker is wiped;
  for wipe-everything install testing use `GHCR_USER=<you> bin/build-local-image
  --push`, which pushes `ghcr.io/<you>/syrus-backend:dev-<sha>` to the fork's
  GHCR (needs `write:packages` in `GHCR_TOKEN` or `~/.config/syrus/ghcr-token`;
  make that package public once so installs need no docker login). Never
  stage a published ref you don't control — a successful pull would clobber
  what you meant to test. install.sh classifies pull failures: exit 30
  network/other, 31 access denied, 32 tag not found.
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
- **SolidQueue queues** — `runs` for heavy workflow RunJobs, including
  implementation, response, graders, and main-branch graders; `merges`
  for auto-merge, rebase, and stack-rebase workflow roots; `chat`
  (dedicated low-concurrency worker) for ChatTurnJob and ChatWorkspaceJob;
  `videos` (low-concurrency) for VideoWalkthroughAnalysisJob, whose
  multi-minute Gemini uploads/polling would otherwise pin default threads;
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
  auto-merge to re-run required graders. Required grader success is recorded
  via `LandingValidationCache`, and later auto-merge or merge-train retries may
  skip revalidation only when the artifact matches the exact PR/integration
  head SHA being landed.
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
- **UTF-8 byte truncation** — never call `String#byteslice` directly outside
  the `String#safe_byteslice` core extension. Use
  `text.safe_byteslice(start, length)` whenever truncating by bytes before
  persistence, logging, prompt rendering, or UI serialization so multibyte
  characters cannot be split into invalid UTF-8.
- **Form validation UI** — React forms should use native validity
  attributes plus route-local error rendering.
- **Toolbar dropdown controls** — interactive toolbar controls that offer a small
  set of choices (like chat mode, model, or effort) use a custom button+listbox
  pattern, not a native `<select>`. The pattern is: a `<button>` with
  `aria-haspopup="listbox"` and `aria-expanded`, paired with an absolutely
  positioned `<div role="listbox">` containing `<button role="option">` items.
  Use `useRef` for the button and dropdown, and a `pointerdown` listener in a
  `useEffect` to close on outside clicks. See `ChatModeSelector`,
  `ChatModelSelector`, and `ChatEffortSelector` in `Compose.tsx` for the
  canonical implementation. Native `<select>` is only for form fields (settings
  pages, edit forms) where browser-native styling and keyboard navigation are
  sufficient.
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
bin/rspec          # serial Ruby suite
bin/rspec-fast     # parallel Ruby suite, excludes :ci_only specs
bin/rspec-ci       # rspec-fast plus :ci_only specs
bin/rspec spec/jobs/run_job_spec.rb   # one file
bin/test-react     # React/Vitest suite + TypeScript typecheck
bin/test           # Ruby and React suites; reports separately
```

React tests run through Vitest and TypeScript. Use `bin/test-react` for
frontend-only changes, or `bin/test` to chain Ruby and React.

Ruby specs are split into the normal fast suite and explicit CI-only specs.
`bin/rspec-fast` is the default full-suite check for local work and Syrus
graders: it runs RSpec in parallel, excludes examples tagged `:ci_only`, emits
normal progress output to stdout, and writes per-worker JSON files to
`.syrus/rspec-json/`. `bin/rspec-ci` first runs `bin/rspec-fast`, then runs
the `:ci_only` examples and writes `rspec-ci-only.json` in the same JSON
directory.

Use CI-only specs sparingly. They are for checks that are too slow, too
environmental, or too broad for normal agent grade loops but still important in
GitHub Actions. A future agent should run CI-only specs when working on a CI
failure workflow, when changing CI/test infrastructure itself, or when the
change touches behavior that is only covered by an existing `:ci_only` spec. Do
not add a spec to `:ci_only` merely because it is failing or inconvenient; first
try to make it fast with fakes, dependency injection, or a narrower assertion.

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
- **Agent prompts go via stdin, not argv.** The adversarial-review prompt
  embeds the full implementation diff; after a long session it exceeded
  Linux's 128 KiB per-argument limit (`Errno::E2BIG`). `AgentInvocation`
  now sends the prompt over stdin (via `--stdin` / piped input). Never
  pass long prompts as positional argv to `claude` or `codex exec`.
  (Commit `77eccaa7`.)
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
app/services/syrus_mcp/                      # all MCP sidecar tools (submit_summary, adversarial_review, memory, etc.)
app/services/prompts/                        # all agent prompts (PORO)
app/services/pr_summarizer.rb                # second-shot fallback
app/jobs/poll_*.rb                           # polling jobs (cron-style; see config/recurring.yml)
app/jobs/reap_stale_runs_job.rb              # kills zombie Runs every minute
app/jobs/workflow_workspace_prune_job.rb     # daily sweep of old terminal workspaces
app/models/terminal_session.rb               # terminal session lifecycle + relay readiness
app/services/terminal_relay.rb               # terminal relay host discovery
app/channels/terminal_channel.rb             # Action Cable bridge to terminal relays
app/jobs/terminal_session_job.rb             # worker-side PTY and relay runner
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
