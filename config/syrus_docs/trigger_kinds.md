# Workflow Trigger Kinds

Every `Workflow` has a `trigger_kind` that identifies what the attempt is for and which step chain it runs. Trigger kinds are defined in `app/models/workflow/trigger_kind.rb`.

## initial

**When it fires:** A new GitHub issue receives the trigger label (or a `direct` or `cron` Job is created).

**Step chain:** `prepare → adversarial_review_loop? → retry_until(implement, graders) → coverage_analyze? → summarize → test_plan → pr_open`

The primary workflow: explores the repo, writes code, runs graders, and opens a PR.

## skill

**When it fires:** A `direct` Job is created with `skill_name` + `skill_args` set (`SkillJobs::Creator`), rather than a free-form prompt.

**Step chain:** `prepare → run_skill → retry_until(run_skill, graders) → summarize → pr_open`

`run_skill` resolves the named skill via `Skills.for` (a repo-local
`.syrus/skills/<name>/SKILL.md` override, or a built-in `Skills::` class),
renders its instructions with `skill_args` substituted, and invokes the agent
the same way `implement` does. There is no dedicated "conditional PR" control
node: like `implement`, `run_skill` raises `Steps::Base::NoChangesProduced`
when the agent commits nothing, which fails the step before the grader retry
loop has anything to grade — `propagate_fail_to_job!` then closes the Job
with `closure_reason: "no_changes"` instead of `:failed`, the same happy path
cron Jobs use for a no-op survey. This makes read-only skills (an
`investigate` skill, an operational skill that only reports) first-class: no
diff is a successful, PR-less outcome, not an error.

The exception is the background-wait misuse pattern: if the transcript shows
the agent backgrounded or scheduled work and ended the turn expecting a later
notification or `ScheduleWakeup` continuation, Syrus raises
`Steps::Base::AgentGaveUpWaiting` and classifies the run as retryable
`agent_gave_up_waiting` instead of closing the Job as `no_changes`.

When the agent does commit a diff, it is gated through the same
`retry_until(agent_step, graders)` mechanism `initial`/`retry` use for
`implement`: `run_skill` repairs, `grader_fanout`/`grader_collect` check, and
a failing check re-runs `run_skill` (not just the graders) up to
`AppSetting.grade_max_iterations` before the workflow fails outright. This
closes the gap where a `skill` Job could open a PR with zero automated
verification. The `adversarial_review`/`visual_review` loops that `initial`
also runs are intentionally not part of the `skill` chain.

Which tier resolved (`skill_source`: `repo_override` or `built_in`) and the
resolved path/class are recorded on the Run so a repo-local skill silently
shadowing a built-in one of the same name is never a debugging trap — see the
Run detail payload and `Admin::JobStateSerializer`.

## pr_comment

**When it fires:** New non-Syrus-bot review comments appear on the Job's PR since the last addressed comment.

**Step chain:** `prepare → retry_until(respond, graders) → coverage_analyze? → coverage_pr_comment? → summarize_amend → refresh_job_metadata → try(push)`

Addresses review feedback, produces revision-scoped commit copy, optionally refreshes canonical Job/PR metadata when feedback changed the effective intent, and pushes. Comments authored by the configured Syrus GitHub App bot are ignored so automated comments such as coverage reports do not self-trigger feedback workflows. Syrus records which `PrReviewComment` rows a workflow is handling, marks them handled only after the workflow succeeds, and leaves failed or rate-limited handling visible on the Job detail pending-feedback panel for manual retry. If the push encounters a non-fast-forward conflict, dynamically inserts an agent-rebase recovery chain.

## chat_feedback

**When it fires:** An operator sends a message in the chat workspace linked to a Job.

**Step chain:** Same as `pr_comment`.

Structurally identical to `pr_comment` but triggered from the chat interface rather than a GitHub review comment. When chat feedback originated from a pending PR comment, the source comment is tied to the workflow and becomes retryable from the pending-feedback panel if handling fails before success.

## ci_failure

**When it fires:** CI checks on the Job's PR fail and the job is configured for CI repair.

**Step chain:** `prepare → retry_until(analyze_and_fix, graders) → summarize_amend → try(push)`

The agent inspects the failing checks and fixes the root cause, then Syrus runs
the repository's configured `ci` phase graders before pushing the fix. Put
CI-only checks in explicit `.syrus.yml` graders with `phases: [ci]` so the
agent can verify that the GitHub CI failure is actually fixed. If graders fail,
their output feeds the next `analyze_and_fix` iteration.

If a later `analyze_and_fix` iteration makes no new diff and repeats a prior
`report_main_concern` diagnosis for the same observed main SHA, failing grader,
and reason, Syrus records `blocked_by_main`, skips that iteration's pending
grader check steps, and continues to `summarize_amend`/`push`. That preserves
any legitimate fixes committed by earlier iterations instead of burning the
full retry budget against a self-diagnosed pre-existing main failure.

`PollPullRequestJob#react_to_ci_failures` skips dispatch entirely — without
spending any of the Job's `CI_FAILURE_CAP` budget — while the repository's
main branch is known-broken (`repository.landing_paused? && repository.main_health_broken?`,
the same condition `StepDispatcher` already uses to hold workflow starts). This
avoids blaming the Job's own diff for a red check caused by a broken base
revision. `main_branch_repair` Jobs are exempt from this guard the same way
they're exempt from the `ci_failure` cap, since a repair job must keep
absorbing CI feedback until main is actually fixed. See `main_branch_repair`
below for what happens to PRs deferred this way once main recovers.

## retry

**When it fires:** Operator triggers a retry of a failed Job from the UI or admin API.

**Step chain:** Same as `initial` (`prepare → retry_until(implement, graders) → summarize → test_plan → pr_open`).

Starts the implementation from scratch on the existing branch.

## manual

**When it fires:** Operator dispatches a free-form prompt from the Job detail page.

**Step chain:** Depends on configuration; typically `prepare → manual_step`.

## resume

**When it fires:** Operator resumes a paused or partially-completed workflow.

**Step chain:** Continues from the step that was interrupted.

## replay

**When it fires:** Operator replays a completed workflow.

Structurally like `retry`; treated identically in most code paths.

## auto_merge

**When it fires:** A Job is approved (via the landing queue) and Syrus is ready to land the PR.

**Step chain:** `mergeability_preflight → prepare → retry_until(graders, repair: landing_fix) → push → auto_merge`

Validates mergeability, mechanically rebases and force-pushes the PR branch onto
the current base when that rebase is clean, re-runs required graders on the exact
rebased PR branch, then merges. If the mechanical rebase conflicts, Syrus
dispatches the normal `rebase` workflow and defers. Landing does not run
`coverage_analyze` because landing graders are pass/fail gates and do not
produce the full coverage flow.
Transient GitHub errors defer the Job back to `approved` for retry. Does not run
`implement` — only landing validation and merge.

## landing_validation

**When it fires:** The `landing_validation_prefetch` feature flag is enabled and
an `auto_merge` or `merge_train` workflow's required landing graders pass while
another ordinary same-repository Job is next in the queue.

**Step chain:** `speculative_landing_build → prepare → grader_fanout → grader_collect`

Infrastructure-only speculative prevalidation. It rebases the next PR onto the
predicted post-merge tree from the current landing workflow and runs fast landing
graders so the later real `auto_merge` may skip duplicate grader work. It never
pushes, repairs, or merges, and failed/cancelled workflows do not fail the Job.

## merge_train_validation

**When it fires:** The `landing_validation_prefetch` feature flag is enabled and
an `auto_merge` or `merge_train` workflow's required landing graders pass while
an eligible Epic merge-train unit is next in the queue.

**Step chain:** `speculative_merge_train_build → prepare → grader_fanout → grader_collect`

Infrastructure-only speculative prevalidation for Epic trains. It builds a
scratch integration branch on top of the predicted post-merge tree from the
current landing workflow, mechanically rebases each member branch into that
scratch integration branch, and runs fast landing graders so the later real
`merge_train` may skip duplicate grader work. It never creates a real
`MergeTrain`, pushes, repairs, or merges, and failed/cancelled workflows do not
fail the Job.

## external_pr_merge

**When it fires:** An `external_pr` Job is approved through the landing queue.

**Step chain:** `mergeability_preflight → prepare → grader_fanout → grader_collect → external_pr_merge`

Validates the externally filed PR and merges it through GitHub's merge API.
Same-repository external PRs are mechanically rebased and force-pushed onto the
current base before landing graders run; conflicts dispatch the normal `rebase`
workflow against the external PR head branch. The workflow prepares the
workspace before running graders but does not run a normal push step.
Same-repository external PRs can run `landing_fix` after grader failures and push
repair commits back to the PR head before merge. Fork PRs skip mechanical rebase
and repair pushes; they receive a `REQUEST_CHANGES` review on required grader
failure and return to `implemented` for re-approval after the contributor pushes
a fix.

## merge_train

**When it fires:** All open child Jobs of an Epic are approved and `AppSetting.merge_train_enabled` is true.

**Step chain:** `merge_train_assemble → merge_train_build → merge_train_reconcile → prepare → retry_until(graders, repair: landing_fix) → merge_train_land`

Atomically lands all Epic child PRs through a single integration branch. See the Merge Train documentation for details.

## rebase

**When it fires:** `PollAllMergeStatesJob` detects that the Job's PR branch is `mergeable: false` and Syrus controls the head branch.

**Step chain:** `auto_rebase → agent_rebase → force_push`

Rebases the PR branch onto the base branch. Skips `commit_agent_changes` (rebase rewrites history). Uses `--force-with-lease` to prevent clobbering concurrent pushes. Closed-preempted Jobs remain in the rebase poll scope while their external PR is open.

## stack_rebase

**When it fires:** A dependent PR stack needs rebasing due to base-branch advancement.

**Step chain:** `stack_auto_rebase → stack_agent_rebase → stack_force_push`

Rebases a chain of dependent PR branches in dependency order, then resumes landing for any approved stack Jobs.

`stack_rebase` is an Epic-wide workflow when the Job belongs to an Epic. Only
one Epic-wide workflow may be active for an Epic at a time, and it blocks
ordinary child Job workflows while it runs. This prevents stack rebases from
force-pushing member branches while a merge train is grading or landing a
captured integration branch.

## coding_handoff

**When it fires:** An operator confirms the handoff after a Coding Mode chat session commits changes.

**Step chain:** `prepare → retry_until(grader_fanout → grader_collect, repair: coding_handoff_fix) → summarize → test_plan → pr_open`

Validates the chat agent's committed work with graders before opening a PR.
If required graders fail, a fresh workflow agent runs `coding_handoff_fix` on
the committed handoff branch, using the original Job context, captured handoff
branch metadata, recent commits, and `Prompts::GradeFailureFeedback`; graders
then retry up to `grade_max_iterations`. The original chat is not queued for
repair. Syrus may post a passive chat notification identifying the Job. On
success it notifies the originating chat after the PR opens, schedules coding
workspace reclaim, then clears the chat link.

## local_mode_handoff

**When it fires:** An operator confirms a handoff from a Local Mode chat session (labs feature `local_mode`).

**Step chain:** When no PR exists: `prepare → grader_fanout → grader_collect → summarize → test_plan → pr_open`. When a PR already exists (taken-over implemented Job): `prepare → grader_fanout → grader_collect → summarize_amend → try(push)`.

Requires operator confirmation before the workflow dispatches. The linked chat
stays attached while graders run and is cleared only after the local-mode
handoff succeeds.

**On grader failure:** The workflow does not propagate failure to the Job via the normal `propagate_fail_to_job!` path. Instead, `after_fail` reverts the Job to `:coding` so the operator can fix the issues and re-run `complete_implement_step`. If a linked chat session exists, the grader failure report is posted there to trigger an agent turn. This makes the "fix → `complete_implement_step` again" cycle documented in coding mode's system prompt work correctly.

**On non-grader failure** (e.g. `prepare` failed): `after_fail` drives the Job to `:failed` manually so the operator has the normal Retry path.

## main_branch_repair

**When it fires:** Spawned automatically by `MainHealthChangedService` when the repository's main branch is detected as broken and Syrus has a settled broken signal from either CI or the main-grader workflow. Repair does not wait for both probes to finish: if CI has already failed, the repair job can start while the main-grader is still running, and vice versa.

**Step chain:** `preflight_grader_fanout → [preflight_grader steps] → preflight_grader_collect → prepare → retry_until(implement, grader_fanout, grader_collect) → summarize → test_plan → pr_open`

The workflow runs a preflight grader check before invoking the agent. If the preflight graders all pass (indicating the broken signal was a false positive), `preflight_grader_collect` cancels the implement chain and the workflow closes immediately — the agent never runs. `after_success` then updates `grader_health` to healthy, calls `MainHealthChangedService.on_health_change!`, and closes the anchor job.

If any required preflight grader fails, the chain continues normally to the implement step. The agent fixes the broken code, graders validate the fix, and a PR is opened. `PollPullRequestJob` calls `MainHealthChangedService.repair_landed!` when the PR merges.

**Recovery sweep:** `MainHealthChangedService#recovered!` runs whenever main
health returns to healthy (either via `repair_landed!` above or an independent
health poll), and — after resuming landing and retrying held Jobs — sweeps the
repository's open Jobs where `pr_checks_state == "failing"` (kept fresh on
every PR poll, so no extra GitHub calls are needed to find candidates). For
each one without an already-active rebase or merge train
(`RebaseWorkflowSelector.active_for_stack?` / `active_merge_train_for_stack?`),
it dispatches a mechanical `rebase` workflow the same way the admin
"force rebase" repair action does. This exists because GitHub does not
silently re-run stale failed check results just because the base branch
changed — without an explicit nudge, PRs left on the broken base would sit red
until something else touched them. Since `rebase`'s `auto_rebase` step tries a
plain `git rebase` first and only escalates to an agent on a real conflict,
the common case is a cheap clean force-push that gives GitHub a fresh SHA to
check against the now-healthy base; the next poll only fires `ci_failure` if
the PR's own diff is genuinely still broken. The fan-out is capped at
`MainHealthChangedService::MAX_RECOVERY_RETRIES` (10, shared with the held-Job
retry sweep) so a big outage's recovery doesn't dogpile the `merges` queue.
There is deliberately no persistent "deferred because main was broken"
marker — querying live `pr_checks_state` at recovery time sweeps up every
red-CI Job regardless of which guard skipped its repair (the `ci_failure`
main-health gate above, the pre-existing `ci_failure` cap, or a race-window
miss), with no bookkeeping to fall out of sync. The recovery notification
includes the rebased-PR count alongside the retried-Job count.

## main_grader

**When it fires:** An internal trigger for running graders against the main branch (used for automated main-branch health checks).

This trigger kind is infrastructure-facing and not surfaced in the operator Job state machine. It does not produce a PR or appear in the normal Job workflow list.

Main-branch CI health is intentionally narrower than "any failed GitHub check on the SHA." For GitHub Actions, Syrus only treats checks from the regular `CI` workflow as the CI signal. Release, test-build, website deploy, and other packaging/operations workflows can fail on the same commit without marking main broken or spawning a main-branch repair job.

**GitHub outage handling:** `PollMainBranchHealthJob` (every 5 minutes, per `config/recurring.yml`) rescues transient GitHub-side failures (`Octokit::ServerError`, `Faraday::TimeoutError`, `Faraday::ConnectionFailed`) around its two GitHub calls instead of letting them crash the job. A single failed poll is normal noise — it's logged, `Repository#main_health_poll_error_streak` is incremented, and `last_main_health_poll_error_at` is stamped; the next scheduled tick retries. Only after `Repository::MAIN_HEALTH_POLL_ERROR_STREAK_THRESHOLD` (3, roughly 15 minutes of sustained outage) *consecutive* failures, and only when `ci_health` is already `"broken"`, does the job downgrade `ci_health` to `"inconclusive"` and call `MainHealthChangedService.on_health_change!` — this reuses the existing inconclusive path (resumes landing, emits a `main_inconclusive` notification) instead of a distinct outage notification, and never fabricates a `"healthy"` result from missing data. Any successful poll resets the streak to zero and normal broken/healthy/inconclusive/not_configured evaluation resumes.

`main_grader` is exempt from user Job start gates and the global agent-run concurrency deferral that would make the health signal stale. It starts and runs even while another Job in the repository has urgent priority, and its RunJobs use an internal Solid Queue priority ahead of user-facing `urgent` Jobs so queued urgent work cannot delay the main-health check. It is also exempt from the broken-main gate because the workflow is the check that measures main-branch grader health.

**Workspace lifecycle:** Infrastructure workflows (those in `Workflow::INFRASTRUCTURE_TRIGGER_KINDS`) clean their workspace immediately on both success and failure — they do not participate in the normal failed-workflow workspace retention. This is enforced at two layers:

1. The `fail` AASM event in `Workflow` calls `cleanup_workspace!` immediately for infrastructure workflows.
2. `WorkflowWorkspacePruneJob#db_sweep` and `#filesystem_sweep` apply `RETAIN_AFTER_SUCCESS_OR_CANCEL` (2 hours) as a backstop for infrastructure failed workflows instead of the normal tiered retention logic.

**Normal (non-infrastructure) failed workflow workspace retention:** Syrus keeps at most one workspace per Job on disk at a time. When a new workflow's first run starts, it eagerly sweeps all sibling workflows' workspace directories (`WorkflowWorkspace#sweep_sibling_workspaces!`), stamping `cleaned_up_at` on each so the "Retry from failed step" button is immediately disabled for superseded workflows.

`WorkflowWorkspacePruneJob` applies a three-tier backstop for any workspaces not caught by the eager sweep:

1. **Non-latest workflow:** pruned immediately on the next prune pass. The eager sweep should have handled these; this is the defense-in-depth backstop.
2. **Latest workflow + job is closed:** pruned after `RETAIN_AFTER_SUCCESS_OR_CANCEL` (2 hours). The job is done; no retry is coming.
3. **Latest workflow + job is open:** retained up to `RETAIN_AFTER_FAILURE` (7 days). The operator may still use "Retry from failed step."

Only the Job's latest workflow is eligible for "Retry from failed step" (`Workflow#retry_available?` checks `latest_for_job?`). The `reopen` AASM event also carries this guard, so a superseded workflow cannot be reopened even by direct API calls.

**Runaway workflow guard:** Syrus closes a Job as `too_many_failed_workflows` after 10 consecutive failed Workflows, and as `too_many_workflows` once it reaches 50 total Workflows. A successful Workflow breaks the failed streak. The total-workflow guard cancels the newly-created Workflow before it starts, so repeated queue wakeups cannot create hundreds of attempts for one Job.

**Retry/Reopen suppression:** Infrastructure Jobs and their anchor workflows are not operator-retryable. The "Retry from failed step", "Retry implementation", and "Reopen" UI actions are suppressed for infrastructure jobs in `App::JobDetailPayload` and `App::JobRetryActions`.
