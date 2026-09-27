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
- `promotion` / `hotfix_sync` / `upstream_export` — delivery-track ref
  movement: promote a track source branch to its target, sync hotfixes back
  from release to development, or export an approved Job branch upstream.
- `coding_handoff` — triggered after a coding-mode chat session commits
  and hands off via `complete_implement_step` (existing Job) or
  `submit_coding_changes` (creates a new direct Job); requires operator
  confirmation before dispatching. Gets the same optional adversarial/visual
  review loops and opt-in `review_plan` step `initial`/`retry` get; since
  there's no bare leading `implement`/`respond` step (the chat session
  already produced the diff), `coding_handoff_fix` plays that repair role,
  and the reviewers fall back to a fresh `git diff` against the default
  branch instead of reading a prior step's diff. On grader pass, opens the
  PR and notifies the linked chat. Review `needs_work` verdicts and grader
  failures are both repaired by `coding_handoff_fix`; terminal grader
  failure posts a passive chat report and marks the Job failed for the
  normal Retry path.
- `local_mode_handoff` — triggered after an operator confirms a Local Mode
  handoff. Graders run in a workflow-owned retry loop repaired by
  `local_mode_handoff_fix`; exhausted grader failures post a passive chat
  report and leave the Job failed for the normal Retry path.
- `landing_validation` / `merge_train_validation` — speculative,
  non-publishing prevalidation for the next landing candidate when enabled.
- `manual_visual_review` — on-demand visual QA over an already-implemented
  Job branch; records the review without looping back into implementation.
- `visual_diff` — low-priority, non-blocking before/after screenshot
  comparison. Automatically queued on a Job right after an approved
  `visual_review` iteration records "after" screenshots; checks out the
  merge-base for `Job#effective_base_branch`, captures matching baseline
  screenshots there, and persists a `visual_diff_comparison` typed artifact
  pairing baseline and PR/head images. Self-cancels/skips once the Job has
  already moved to approval/landing (`obsolete_job_state?`), and never
  blocks approval or landing (`Workflow::TriggerKind::NON_APPROVAL_BLOCKING_VALUES`).
  Also available on demand via the Job detail page's "Run before/after
  comparison" action.
- `main_grader` / `main_branch_repair` / `agent_insight` / `deploy` —
  infrastructure/operations workflows for default-branch health, read-only
  insight generation, and configured deploy commands.

### Per-Workflow pipeline (`app/jobs/run_job.rb`, `app/services/workflows/`, `app/services/steps/`)

Each Workflow runs a named chain of Steps. Workflow definitions live in
`app/services/workflows/`; step handlers in `app/services/steps/`. All Steps
in a Workflow share one `WorkflowWorkspace` (shallow clone at
`$SYRUS_DATA_ROOT/workflows/<workflow_id>/`). Workspace lifecycle is tied to
Workflow terminal transitions (not per-Step ensure). `WorkflowWorkspacePruneJob`
sweeps old terminal workspaces after 7 days.

Current chains:

```
initial:     prepare → implement → [loop(adversarial_review first, then implement ⇄ adversarial_review)] → [loop(visual_review first, then implement ⇄ visual_review)] → retry_until(format → generate → graders; repair: implement) → coverage_analyze → dependency_audit → summarize → test_plan → pr_open → review_plan
pr_comment:  prepare → respond → [loop(adversarial_review first, then respond ⇄ adversarial_review)] → [loop(visual_review first, then respond ⇄ visual_review)] → retry_until(format → generate → graders; repair: respond) → coverage_analyze → coverage_pr_comment → dependency_audit → dependency_audit_pr_comment → summarize_amend → refresh_job_metadata → try(push)
chat_feedback: prepare → respond → [loop(adversarial_review first, then respond ⇄ adversarial_review)] → [loop(visual_review first, then respond ⇄ visual_review)] → retry_until(format → generate → graders; repair: respond) → coverage_analyze → coverage_pr_comment → dependency_audit → dependency_audit_pr_comment → summarize_amend → refresh_job_metadata → try(push)
ci_failure:  prepare → retry_until(analyze_and_fix → graders) → summarize_amend → try(push)
retry:       prepare → implement → [loop(adversarial_review first, then implement ⇄ adversarial_review)] → [loop(visual_review first, then implement ⇄ visual_review)] → retry_until(format → generate → graders; repair: implement) → coverage_analyze → dependency_audit → summarize → test_plan → pr_open → review_plan
rebase:      auto_rebase → agent_rebase → force_push
stack_rebase: stack_auto_rebase → stack_agent_rebase → stack_force_push
auto_merge:  mergeability_preflight → prepare → retry_until(graders, repair: landing_fix) → push → auto_merge
landing_validation: speculative_landing_build → prepare → graders
merge_train: merge_train_assemble → merge_train_build → merge_train_reconcile → prepare → retry_until(graders, repair: landing_fix) → try(merge_train_land; base-moved fallback: merge_train_rebase → merge_train_agent_rebase → retry_until(graders, repair: landing_fix) → merge_train_land_after_rebase)
merge_train_validation: speculative_merge_train_build → prepare → graders
coding_handoff: prepare → [loop(adversarial_review first, then coding_handoff_fix ⇄ adversarial_review)] → [loop(visual_review first, then coding_handoff_fix ⇄ visual_review)] → retry_until(graders, repair: coding_handoff_fix) → summarize → test_plan → pr_open → review_plan
local_mode_handoff: prepare → retry_until(graders, repair: local_mode_handoff_fix) → summarize/test_plan/pr_open or summarize_amend/try(push)
external_pr_ingest (same-repo): prepare → retry_until(graders, repair: landing_fix) → push
external_pr_ingest (fork):      prepare → grader_fanout → grader_collect
external_pr_merge: mergeability_preflight → prepare → graders[/landing_fix] → external_pr_merge
external_pr_feedback: prepare → respond → [loop(adversarial_review first, then respond ⇄ adversarial_review)] → retry_until(graders; repair: respond) → summarize_amend → try(push)
skill:       prepare → run_skill → retry_until(run_skill → graders) → summarize → pr_open
promotion:   promotion_assemble → prepare → promotion_repair → retry_until(graders, repair: promotion_repair) → promotion_publish
hotfix_sync: hotfix_sync_assemble → prepare → hotfix_sync_repair → retry_until(graders, repair: hotfix_sync_repair) → hotfix_sync_publish
upstream_export: upstream_export_publish
main_grader: prepare → grader_fanout → grader_collect
main_branch_repair: prepare → preflight_graders → retry_until(implement → graders) → summarize → test_plan → pr_open
agent_insight: [prepare] → agent_insight_run → auto_close
deploy:      prepare → deploy
visual_diff: prepare → visual_diff
```

`[loop(...)]` steps are conditional: the `adversarial_review` loop only appears when `adversarial_review_rounds > 0` (per `.syrus.yml` or `AppSetting`); the `visual_review` loop only appears when `visual_review.enabled` is true (per `.syrus.yml`, which defaults to on instance-wide — there is no instance-wide Feature flag for it); `coverage_analyze` only appears when a coverage plan is configured for the repository. `dependency_audit` (and, in feedback workflows, `dependency_audit_pr_comment`) is always present in these chains but self-skips at runtime unless the PR diff touched a lockfile a registered `:dependency_audit_command` plugin owns. In `initial`/`retry`/`pr_comment`/`chat_feedback`, the grader retry loop is likewise conditional at the step level: `format`, `generate`, and the `grader_fanout`/`grader_collect` check phase are only materialized when the repository's `.syrus.yml` configures `formatters:`, `generated:`, or `grade:` respectively (`RepoGradeLoopPlan`, resolved pre-clone the same way as the adversarial/visual review plans — `RepoAdversarialReviewPlan`, `RepoVisualReviewPlan`, `RepoGradeLoopPlan`, `RepoReviewPlanPlan`, and `RepoCoveragePlanReader` are thin adapters over one shared `RepoDefaultBranchSyrusYml` loader that fetches and parses the repository's default-branch `.syrus.yml` through GitHub exactly once; `Workflows::Initial`/`Retry`/`CodingHandoff`/`MainBranchRepair`/`LocalModeHandoff` resolve it once at the top of `steps_for` and thread it through via `syrus_yml:` instead of each helper triggering its own GitHub round-trip) — none of the three is configured by default, so a freshly onboarded repo gets a bare `implement`/`respond` step (or, in `initial`, nothing extra — the top-level `implement` already covers it) with no grade loop at all. As soon as any one of them is configured, the whole loop materializes together (the agent step, whichever of `format`/`generate` apply, and `grader_fanout`/`grader_collect`) — there is no way to retry without a check phase. This conditional gating is scoped to those four autofix-enabled chains; `ci_failure`, `skill`, `main_branch_repair`, and `external_pr_feedback` always materialize their grader check unconditionally since grading is the entire point of those repair loops.

Every review loop (`adversarial_review`, `visual_review`), in every chain that has one, is review-first: iteration 1 is the reviewer alone, reviewing whatever agent step already ran before the loop — a bare top-level `implement`/`respond` step (`initial`, `retry`, `pr_comment`, `chat_feedback`, and `external_pr_feedback` all lead with one, immediately after `prepare`), or, for the second loop in a chain, the first loop's own last repair. A `needs_work` verdict always gets a repair reaction — the corresponding `implement`/`respond` step is inserted unconditionally, regardless of remaining review budget — paired with another review whenever budget remains (iteration N's repair pairs with review N+1 as long as N < rounds); once the review that just ran was the last one `rounds` allows, its `needs_work` repair runs alone, with no further review to act on. `rounds: N` means exactly N review opinions get sought, and every one of them — including the last — gets exactly one repair reaction; the loop never ends on an unreacted-to `needs_work`, and it never fails the workflow (that's what distinguishes it from the grader retry loop below, which genuinely can exhaust its budget and fail). See `Workflows::Loop` and `StepDispatcher#enqueue_next_loop_iteration!`/`#final_review_iteration?`.

The grader retry loop's `repair_first:` (default `true`) mirrors this shape: `initial`, `retry`, `pr_comment`, `chat_feedback`, and `external_pr_feedback` all pass `repair_first: false`, since each already has a bare `implement`/`respond` step (or a review loop's last repair) that ran before the grader loop — so the first grading pass runs `format`/`generate`/graders (or, for `external_pr_feedback`, which has no `.syrus.yml`-driven format/generate config to apply, just graders) directly against that work, and `implement`/`respond` only reappears as a repair step once a grader iteration fails. `ci_failure`, `skill`, and `main_branch_repair` have no such prior agent step and keep the default `repair_first: true`. See `Workflows::Base.adversarial_review_loop`/`.visual_review_loop`/`.grader_retry_loop`.

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
- **`format`** / **`generate`** — Non-agentic, deterministic repair steps
  inserted between the agentic step and `graders` inside the grader retry
  loop of `initial`, `retry`, `pr_comment`, and `chat_feedback` (not
  `ci_failure`, `skill`, or any landing/maintenance workflow) — they rerun on
  every repair iteration, not just once. Both are diff-scoped: a command only
  runs when `git diff --name-only <base>...HEAD` touches the files/sources it
  cares about. `format` runs `.syrus.yml`'s `formatters:` array when it is a
  non-empty array (explicit commands); with no `formatters:` key at all, no
  formatting runs — the safe default, since a repo that never opted in
  should never receive unsolicited autocorrect commits. `formatters: []` (an
  explicit blank array) is the opt-in signal to fall back to the
  `:autofix_command` plugin providers (RuboCop, ESLint/Prettier, gofmt,
  ruff/black) instead; `formatters: false` (or `off`) disables both. `generate` runs `.syrus.yml`'s `generated:` array
  the same diff-scoped way (no plugin-provided fallback — codegen is too
  repo-specific to guess), skipping `codegen_ignore` entries; `generated:
  false`/`off` disables it. Both commit whatever they change and never fail
  the workflow — a command failure is logged as a non-fatal warning, the same
  soft-fail posture `prepare`'s auto-detected commands use. See
  `config/syrus_docs/syrus_yml.md` and `config/syrus_docs/workflow_steps.md`
  for the full `.syrus.yml` schema and step contract.
- **`run_skill`** — Agentic step of `skill` workflows (the skill-workflow feature). Resolves the
  Job's `skill_name` via `Skills.for(repository:, name:)` (repo-local override,
  else built-in), renders the resolved `Skills::Definition`'s instructions with
  `skill_args` substituted (`Skills::Renderer`, `Prompts::Skill`), and invokes
  the agent the same way `implement` does — commit locally, verify branch
  history, capture the diff. Records `skill_source` (`repo_override`/
  `built_in`) and the resolved path/class onto the Run (provenance
  requirement — never a silent shadowing trap). A skill run with no diff (a
  read-only `investigate` skill, an operational skill that only reports) is a
  valid outcome: like `implement`, it raises `Steps::Base::NoChangesProduced`,
  which fails the step before the grader retry loop has anything to grade —
  `propagate_fail_to_job!` closes the Job with `closure_reason: "no_changes"`
  instead — the same happy path cron Jobs use, so the grader loop,
  `summarize`, and `pr_open` never run and no PR is opened. When the agent
  does commit a diff, it is gated through `retry_until(run_skill → graders)`
  the same as `initial`/`retry`'s `implement` loop — bounded by
  `AppSetting.grade_max_iterations` — before `summarize`/`pr_open` run;
  `adversarial_review`/`visual_review` are intentionally not part of this
  chain. `Steps::Summarize` recognizes both `implement` and `run_skill` as the
  upstream agentic step it resumes from. `SkillJobs::Creator` is the Job
  creation entry point: validates the skill resolves and `args` satisfy its
  parameter schema, then creates a `direct` Job with `skill_name`/`skill_args`
  set; `Job#create_initial_run` reads those to dispatch `Workflows::Skill`
  (trigger_kind `skill`) instead of `Workflows::Initial`.
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
  like website builds that only matter when relevant files changed. A registered
  `:affected_test_analyzer` plugin can additively expand that changed-file set
  with real import/dependency-graph analysis before matching (e.g. Ruby's
  `require_relative` graph plus `app`/`lib` <-> `spec` convention) — it can only
  turn a would-be skip into a run, never the reverse, so no analyzer / a
  declining analyzer / an erroring analyzer all fall back to plain glob
  matching against the raw diff. When the repository uses distributed workflow
  execution, any workflow's grader fanout may dispatch multiple grader Runs in
  parallel; `grader_collect` waits for every required result before deciding
  whether repair is needed.
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
  branches work under App or PAT credentials. Build then **pushes the
  integration branch and records it as
  `WorkflowWorkspace::REQUIRED_BRANCH_ARTIFACT`**: workspaces live on
  node-local disk while each Run is claimed by whichever worker is free, so a
  train routinely resumes on a machine that re-clones — and with the
  integration branch unpublished, that re-clone fell back to `job.branch_name`
  and every later step graded, repaired and would have force-pushed a single
  *member* branch while reporting on the train. Land pushes the integration
  branch, merges one integration PR into base, comments on and closes the
  member PRs, and deletes the integration branch;
  `MergeTrainFailureHandler` deletes it on the failed/cancelled path.
- **`merge_train_reconcile`** — Agentic pass between `merge_train_build` and
  `prepare` that runs on the just-built integration branch, allows a no-op
  success, and commits focused reconciliation changes (e.g. cross-member
  conflicts the mechanical rebase couldn't see) before the grading loop runs.
  Unlike `merge_train_build`/`merge_train_land`, it doesn't publish or mutate
  shared landing state, so `RetryFailedStepEnqueuer` resumes/retries it in
  place on failure (same as `implement`) instead of discarding the whole
  train and rebuilding through `LandingRetrier` — the deciding factor is
  the failed step's `Step::Kind#repair_semantics` (`:agentic` steps resume in
  place; `:rebuild`/`:publication` steps force a full merge-train rebuild).
- **`merge_train_rebase`** / **`merge_train_land_after_rebase`** — Base-moved
  recovery for merge trains. If `merge_train_land` detects that the base branch
  moved during grading or landing (`merge_train_base_moved`), the workflow's
  `Try` node inserts `merge_train_rebase`, which incrementally rebases the
  integration branch onto the new base tip, records the fresh base SHA, and can
  carry forward a green grade when `Repository#trust_clean_rebase_grade?` allows
  it. A clean mechanical rebase skips `merge_train_agent_rebase`; a conflicted
  rebase leaves the in-progress rebase for that agentic step to finish. The
  workflow then runs a fresh landing grader loop and finishes with
  `merge_train_land_after_rebase`, a `MergeTrainLand` subclass that reuses the
  same push, merge, member reconciliation, and cleanup behavior against the
  updated integration branch.
- **`adversarial_review`** — Independent critic agent that reads the issue
  and the diff from the preceding `implement` (or `respond`) step, then calls
  `submit_adversarial_review(verdict, critique)`. Verdict `approved` exits the
  loop (findings carry forward but no re-implement needed); `needs_work`
  always triggers a repair `implement`/`respond` iteration — paired with
  another review while budget remains, repair-only once the review that just
  ran was the last one `rounds` allows. The reviewer's
  workspace changes are discarded — it is read-only. Runs in feedback
  workflows (`pr_comment`, `chat_feedback`), `initial`, and `retry`; skipped
  in `ci_failure`, `auto_merge`, and maintenance
  workflows. `.syrus.yml` accepts an optional `criteria` array in the
  `adversarial_review` block to inject repository-specific checklist items
  into the reviewer prompt (additive — the default checklist still runs).
- **`visual_review`** — Independent QA agent that drives a headless browser
  (via the browser MCP tool set) against its own `start_preview` instance to
  catch visible defects, then calls `submit_visual_review(verdict, critique)`.
  Verdicts: `approved` (looks correct), `needs_work` (always triggers a repair
  `implement`/`respond` iteration, paired with another review while budget
  remains), `skipped` (not visually testable — exits the loop the same as
  `approved`). Before spending an agent turn, a
  deterministic `visual_review.when_files_changed` pre-filter can skip the
  step outright (mirrors `grader_fanout`'s glob matching). When it does run,
  the agent reads the `submit_test_plan` artifact's `visual_review_recommended`
  / `visual_review_reason` fields (set by the implementing agent) as a hint,
  but makes its own independent go/no-go call before launching a preview; on
  go, it reads `visual_review.seed_notes`, may run ad hoc seed commands via
  its normal shell access, captures "after" screenshots via
  `submit_visual_artifact`, and always calls `stop_preview` before exiting.
  The reviewer's workspace changes are discarded — it is read-only. Runs
  immediately after the `adversarial_review` loop, before the grader retry
  loop, in `initial`, `retry`, `pr_comment`, and `chat_feedback`; gated by
  `visual_review.enabled` in `.syrus.yml`, which defaults to on instance-wide
  (there is no instance-wide Feature flag for it — a repository opts out per
  repo via `.syrus.yml`); skipped in `ci_failure`, `auto_merge`, and
  maintenance workflows.
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
  open the PR if needed. First restores the validated implementation from its
  `RunCheckpoint` when the workspace lacks it: a Job's branch is local-only
  until this step pushes it, and workspaces are node-local while Runs go to any
  free worker, so a hop between `implement` and here yields a fresh clone off
  the base with no implementation (the empty-workspace PR-open regressions).
  `RunCheckpointPublisher` already publishes every mutation step's commit for
  this purpose — only `summarize`/`summarize_amend` used to restore from it.
- **`review_plan`** — Optional, best-effort agentic step after `pr_open` in
  chains ending with `initial_pr_finish_steps`. Opt-in via `.syrus.yml`
  `review_plan: true` (a bare boolean, not a nested block); materialized
  only when `RepoReviewPlanPlan` resolves the repository as opted in (read
  pre-clone, the same way the adversarial/visual review plans are), so an
  unconfigured repository gets no `review_plan` Step at all rather than one
  that runs and self-skips. Resumes the agent from the last successful `implement` session
  and asks it to call `submit_review_plan` with a handful of specific,
  high-signal "pay attention to X because Y" points anchored at
  `file`/`line`, then posts (or upserts, by marker) a PR comment formatted
  from the artifact — an empty item list posts nothing. Unlike other
  agentic steps, `review_plan` must never fail the parent Job/Workflow: any
  `StepFailed` raised anywhere in the step (agent error, missing tool call,
  MCP sidecar unavailable, GitHub API failure) is caught and logged inside
  the handler; `fail_policy: :advance` on the `Step::Kind` entry is a
  declarative backstop for the same guarantee.

**MCP sidecar** — `bin/syrus-mcp-sidecar`, spawned by the agent CLI over stdio
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
`list_repository_test_insights`, `read_test_insight`,
`read_job_test_results`, `read_run_test_results`, and
`compare_test_runtime` — read-only Test Insights access for bounded flaky,
failing, and slow-test investigation; prefer these over scraping transcripts
when structured test data exists;
`read_performance_diagnostics` — sanitized current/all-revision performance
summaries, available only to implement agents working on `tkadauke/syrus` or a
registered fork;
`submit_summary(pr_title, pr_body, summary)`,
`submit_test_plan(steps, notes)`, and
`submit_review_plan(items, summary)` — write to Workflow `artifacts` and
append `JobLog` audit lines;
`submit_report(title, narrative, findings, references)` — used by the
`submit_report` step of `investigation` Workflows to store the Job's
no-PR narrative deliverable on `Workflow#artifacts["investigation_report"]`;
`references` is an ordered list of `{ type, caption }` pointers back at
evidence already captured this run via `submit_artifact`/
`submit_visual_artifact` — each `type` must match an existing
`typed_artifacts` entry, so the report can never carry a dangling pointer;
`submit_artifact(type, title, payload)` — store a typed, named structured artifact
under `Workflow#artifacts["typed_artifacts"]`; idempotent on `type` (replaces any
prior entry with the same type); available to implement, summarize/test-plan, and
rebase-conflict agents; use for structured outputs reviewers can see rendered
(e.g. `rails_schema_erd`, `rails_migration_diff`);
`list_artifacts(workflow_id)` and `read_artifact(workflow_id, type)` — read-only
companions to `submit_artifact`/`submit_visual_artifact` (also on the chat
sidecar, scoped by the same Job/repository ownership other chat read tools use);
`list_artifacts` returns each `typed_artifacts` entry's type/title/content_type/
byte_size/run_id/step_id/iteration/image_url so an agent can discover the `type`
key a screenshot was actually stored under without guessing; `read_artifact`
returns the stored image as an MCP image content block, the same way
`browser_screenshot` already hands an agent real image bytes it can see this
turn;
`patch_workflow(step_kinds, after_kind, reason)` — lets an implementing agent
add a check to its own running workflow when the work turns out to need one the
template did not include. Append-only and attributed: it cannot remove a step
and cannot add one that publishes (`pr_open`, `push`, `auto_merge` and
siblings), so the checks a workflow exists to satisfy cannot be patched away by
the thing being checked. See `WorkflowPatch`;
`submit_job_metadata(changed:, ...)` — used only by `refresh_job_metadata`;
`submit_adversarial_review(verdict, critique)` — used by the `adversarial_review` step;
`submit_visual_review(verdict, critique)` — used by the `visual_review` step;
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
the landing queue. **`LandingFailureHandler` decides whether a member keeps its
approval**: deferral (stays `approved`, queue retries) for rebuild-required,
landing-start blockers, the rebase cap, and `TRANSIENT_BLOCKER_PATTERNS`
(GitHub 5xx, sidecar failures, worker death, lock contention); failure (reverts
to `implemented`, clears approval, needs an operator) only for genuine
rejections like failed graders. Put a new failure path on the right side of
that split — the wrong side costs an operator a round of re-approving a whole
train. An integration branch with nothing ahead of base is settled against the
base tip rather than pushed (GitHub answers 422 "No commits between"), and a
member that has left `:landing` by assemble time asks for a rebuild rather than
failing the train.

**PR feedback watermarking** tracks both `last_seen_comment_at` and
`last_feedback_addressed_at`; successful `pr_comment` workflows mark the
newest addressed comment, and future polls use the later timestamp as the
cutoff so already-handled feedback is not re-enqueued. `PollPullRequestJob`
also guards against a stale-approval race: `Job#active_feedback_workflow?`
blocks re-approving a Job (both the single- and multi-approver paths) while a
`pr_comment`/`chat_feedback` workflow triggered by fresh feedback is still
queued/running, and `ApprovalPropagator#dismiss` looks up and dismisses the
PR's current `APPROVED` review even when Syrus never captured a
`github_review_id` locally (e.g. the approval came from a raw GitHub review).
The same poller skips dispatching a `ci_failure` workflow while `job.landing?`
is true, so CI repair never fights an in-flight landing attempt. It also gates
CI repair on a clean base: if the PR is behind its base branch, it dispatches
a rebase first instead of repairing against a stale diff; if the base SHA's
health isn't already known-healthy, it defers repair and triggers a main
branch health check instead of possibly repairing against a broken base; and
it suppresses a second `ci_failure` workflow when another one is already
handling the same base SHA for the repository (`PollPullRequestJob#ci_repair_base_not_ready?`).

**Main-branch health & repair** — Syrus grades the default branch itself, not
just PR branches. An internal `main_grader` Job/Workflow (`Job#kind ==
"main_grader"`, filtered out of the operator dashboard) periodically re-runs
required graders on `main`; when they fail, `MainHealthChangedService` opens
an urgent `direct` Job with `kind: "main_branch_repair"` to fix it. Both
trigger kinds are exempt from `AppSetting.max_concurrent_agent_runs` (see
`RunJob#defer_for_agent_concurrency?`) so a saturated agent-run cap can never
starve the health signal or block fixing main, and `StepDispatcher` pauses
other workflows (`start_blocked_reason: "main_branch_broken"`,
`StepDispatcher::MAIN_HEALTH_BLOCK_REASON`) — including landing — until
health is restored. Agents can also proactively flag suspected main breakage
via the `report_main_concern` MCP tool (see above).

### Terminal feature

Interactive terminal access ships as the `terminal` plugin and is off by
default. Enable it from Admin -> Plugins, or with:

```ruby
PluginRecord.find_by(name: "terminal").update(enabled: true)
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
`pr_closed`. `ClosedPullRequestResolution` reads `BranchPatchPresence.classify`,
which runs `git cherry` against the PR base and returns three outcomes, not two:
every commit patch-equivalent on base (`ALL_LANDED` → `pr_merged` — a merge
train landed a rebased copy, or someone cherry-picked it), no commits ahead of
base at all (`NO_COMMITS` → `no_changes`), or real unmerged commits
(`HAS_UNIQUE` → `pr_closed`); an unrunnable check assumes `HAS_UNIQUE`.
Collapsing the first two — the old behavior — filed landed work as "this Job
produced nothing" (the already-landed closed-PR regression). Both `no_changes` and `pr_merged` are successful
parent resolutions for dependency gates, stack rebases, and landing queue
wakeups; the distinction is about attribution.

**A rebase never empties a branch.** When `auto_rebase`'s deterministic rebase
leaves no commits ahead of base, the work already landed; `AutoRebase` returns
`ALREADY_LANDED_REASON` instead of pushing (`Steps::ForcePush` refuses too, for
retried Runs), and `Steps::AutoRebase` closes the Job `pr_merged` and closes the
PR. Force-pushing there would leave the branch at the base tip, empty the PR to
zero commits, and destroy the only record of what the Job did.

**Failure resilience** — failed Runs persist a `RunFailureClassification`
from diagnostics, recent logs, spawned process outcomes, and agent outcome.
`WorkEngine::RepairExecutor` schedules transient-failure retries through
`AutoRetryAttempt` and `AutoRetryJob` — up to three attempts with 5m/20m/1h
backoff, either from the failed Step while the workspace remains or as a fresh
retry Workflow. **The retry budget is the only thing that terminates that
loop**, so every prefix in `AutoRetryAttempt::BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES`
must name a *transient* condition; a permanent one there means the skip never
advances the budget, the planner keeps seeing room, and attempts accumulate at
~2/second (production has hit this twice — see
`config/syrus_docs/work_engine_reconciler.md`). Non-retryable skips use
`AutoRetryAttempt::NOT_RETRYABLE_SKIP_PREFIX`, which is not exempt. Failed agentic runs with captured sessions can resume from the
failed Step instead of starting over. `ProviderCircuitBreaker` suppresses
automatic retries/CI repair during provider-wide transient outages.
`ReapStaleRunsJob` and `ReconcileJobStatesJob` are thin delegators that call
`WorkEngine::Reconciler.request`; the reconciler handles stale Runs, orphaned
queued Runs, queued Workflows with no first Run, terminal orphan Workflows,
and missed worker-death auto-retries.

### Scheduled tasks

`ScheduledTasks::Task` (the bundled `scheduled_tasks` plugin, on by default)
lets the operator attach recurring or one-shot agent
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
committing anything. The Job closes with `closure_reason: "no_changes"`,
counts as successful, and satisfies downstream dependencies.

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
semantics as the workflow `prepare` step), builds its subprocess env through
the same `Steps::Prepare.prep_env_forward`/`.prep_extra_env` (`:step_environment`
plugin extension point) `Steps::Prepare`/`Steps::Grader` use rather than a
private hardcoded list, so a plugin like `build_cache`'s sccache configures
consistently there too (see `ChatWorkspaceEnv`, `PrepareScope`, and
`plugins/build_cache/docs/syrus_docs/sccache_build_cache.md`) -- the same
helper also backs `ChatShellCommandExecutor::Coding`'s ad hoc `!` commands --
and agents can inspect the checkout prep state before assuming dependencies
are ready. Chat has a
`reset_workspace` MCP tool that is status-only by default and requires
`confirm_discard: true` before it discards dirty or ahead-of-default Coding
Mode work and prepares a fresh branch. After committing, the agent
calls `complete_implement_step` (to hand off an existing Job) or
`submit_coding_changes` (to create a new direct Job from the branch) —
both create a pending action that requires operator confirmation before
the `coding_handoff` Workflow is dispatched. While a chat turn is busy,
follow-up user messages are stored as `ChatQueuedMessage`s and delivered
sequentially after the current turn finishes.

In **Local Mode**, `complete_implement_step` also creates a pending action
that the operator must confirm before dispatch. After confirmation, the
`local_mode_handoff` workflow owns grader repair through
`local_mode_handoff_fix`; failed grader repair reports back passively instead
of promoting the linked chat into another agent turn.

Planning-mode preview mockups use the `mockups` plugin MCP tools:
open a panel with `show_preview`, write or patch files in that panel's
scratch directory with `write_preview_file` / `edit_preview_file`, then call
`show_preview` again with the same `panel_id` to publish. Publishing records a
`Mockups::Mockup` -- slug `MOCKUP-<id>`, stable across republishes -- which
backs the **Mockups** sidebar page: a filter-bar-searchable list whose rows open
in a side panel. `PreviewPanel`/`PreviewPanelVersion` stay core (a generic
html/markdown/pdf/image viewer); the plugin is a client of them. Two core seams
make that possible: the `preview_panel_viewer` extension point, which lets a
plugin add a content kind without editing
`PreviewPanel::EntryMetadata` (core's kinds still win), and
`/api/v1/app/preview_panels/:id`, which serves panel content outside the chat
it was opened in, scoped by `PreviewPanel.accessible_to`. Preview panel
versions can be attached to proposed Jobs as `preview_panel_version:<id>` so
implementation agents receive the source files, not just a screenshot.

`ChatWorkEvents.publish!` (formerly `SupervisorEvents`, before the admin
Supervisor chat feature was removed) records scoped operational events for
ordinary chats that originated the referenced work, resolved through
confirmed proposal lineage (`ChatScopedEventRecipients`); a disposable
`ChatScopedEventEvaluatorJob` reviews each event with read-only tools and
either records `no_op` or creates a real `ChatWakeup` (`respond`/`act`). The
handoff prompt tells the agent to read current Syrus state before acting on
event payloads and to keep risky side effects behind proposals or
pending-action confirmation.

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
apply.

**Walkthrough videos (video → Epic)** — the bundled `video_walkthroughs`
plugin, off by default (Admin -> Plugins). The plugin is its own feature flag;
the old `video_walkthroughs` Labs entry is gone. When it is off: the composer
hides recording/video intake (the plugin stops contributing
`paths.app_video_walkthroughs_path`), the upload/retry endpoints answer
`plugin_disabled`, `VideoWalkthroughs::AnalysisJob` fails the row terminally,
a walkthrough chat message no longer claims the turn (the plugin's
`chat_turn_orientation` provider is withheld), and the three walkthrough MCP
tools are not advertised because `VideoWalkthroughs::ChatToolSet` is withheld
— while already-analyzed threads keep their history (media panel + message
cards render read-only) and `VideoWalkthroughs::PruneJob` keeps enforcing
retention on the plugin's own daily tick. When ON — chats accept
narrated screen
recordings (composer `+ → Record a walkthrough`, drag-in, or file picker;
webm/mp4/mov, ≤15 min, ≤500 MB). `VideoWalkthroughs::Walkthrough` (Active Storage)
uploads via multipart `POST /api/v1/app/chats/:chat_id/video_walkthroughs`;
`VideoWalkthroughs::AnalysisJob` (queue `videos`, low-concurrency) runs Gemini —
Files API resumable upload → poll ACTIVE → one `generateContent` with a JSON
`responseSchema` (`VideoWalkthroughs::Prompts::Analysis`) at FULL
`media_resolution` (LOW measurably garbles small on-screen text; the job
retries at LOW only if a ≥12-min video's full-res attempt is actually
rate-limited — graceful degradation, `VideoWalkthroughs::Gemini::Client::LOW_RESOLUTION_FALLBACK_SECONDS`).
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
or `read_walkthrough_frame`, below) and `VideoWalkthroughs::Prompts::Report` steers it
to READ the exact characters off the screenshot and never invent one it can't
read. Flagged issues (`needs_closer_look` or a non-empty `unreadable_text`) are
captured at top OCR-grade `HIGH_JPEG_QUALITY` and prioritized to survive the
per-response `MAX_FRAMES` cap. **Segment "zoom in"** — the Gemini Files API retains the
upload ~48h, so `Gemini::Client#analyze_segment` re-analyzes a CLIP of the SAME
file at full resolution with no re-upload (a `video_metadata` `{ start_offset:
"12s", end_offset: "30s" }` sibling of `file_data`). The chat MCP tool
`analyze_walkthrough_segment(walkthrough_id, start, end, focus)`
(`VideoWalkthroughs::AnalyzeWalkthroughSegmentTool`, deferred, `VideoWalkthroughs::Prompts::Segment`)
lets the chat agent get finer detail (exact error text, click sequence) on
`needs_closer_look` moments or on request; it re-uploads the stored blob when
the file is past retention, and reports "video expired" only when the blob is
also pruned. Test seam `VideoWalkthroughs::AnalyzeWalkthroughSegmentTool.client_factory`.
**On-demand still (`read_walkthrough_frame`, deferred)** —
`VideoWalkthroughs::ReadWalkthroughFrameTool` lets the chat agent pull a crisp
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
visible) → `VideoWalkthroughs::Gemini::VideoTranscoder` transcodes the source to a compact 720p mp4
that REPLACES the stored blob (empirically Gemini analyzes the compact mp4 as
well as the original — the narration carries the context — best-effort, keeps the
original on failure).
**First-class handoff (NOT a spoofed user message):** the job then posts the
VIDEO itself as a chat message (`video_walkthrough_id` + the operator's note),
shown in the thread as a walkthrough card and in the media panel. `ChatTurnJob`
detects that message and orients the agent with the SHORT
`VideoWalkthroughs::Prompts::Context` (names the tools, does not dump the analysis);
the agent then calls `get_walkthrough_analysis` (returns the report +
on-demand crisp stills as MCP image blocks) and works autonomously toward an Epic
— every step a real `tool_use`/`tool_result` chat event you can trace. Gemini is
the eyes, the chat agent stays the brain. Auth is an AI Studio API key only
(`User#gemini_api_key`, encrypted; validated via free `models.list` —
`CredentialProbe.gemini_key`, model resolved at analysis time by
`VideoWalkthroughs::Gemini::Client#resolve_video_model!` against `VIDEO_MODELS`): the gemini-cli
OAuth path has no Files API and reusing its OAuth client violates Google ToS.
Videos are Active Storage blobs on Disk/S3 (NOT inlined in SQLite — only the
metadata row is). `VideoWalkthroughs::PruneJob` (daily) enforces both a time
ceiling (`AppSetting.video_retention_days`, default 7) and an instance-wide
size budget (`AppSetting.video_storage_budget_bytes`, LRU eviction, default
2 GB, 0 = unlimited) on the stored video blobs — the analysis + screenshots
always persist. Test seams: `VideoWalkthroughs::AnalysisJob.client_factory`,
`CredentialProbe.gemini_client_factory`, `VideoWalkthroughs::Gemini::FrameExtractor.runner`,
`VideoWalkthroughs::Gemini::VideoTranscoder.runner`.
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

