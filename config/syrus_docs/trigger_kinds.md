# Workflow Trigger Kinds

Every `Workflow` has a `trigger_kind` that identifies what the attempt is for and which step chain it runs. Trigger kinds are defined in `app/models/workflow/trigger_kind.rb`.

## initial

**When it fires:** A new GitHub issue receives the trigger label (or a `direct` or `cron` Job is created).

**Step chain:** `prepare → adversarial_review_loop? → retry_until(implement, graders) → coverage_analyze? → summarize → test_plan → pr_open`

The primary workflow: explores the repo, writes code, runs graders, and opens a PR.

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

**Step chain:** `prepare → analyze_and_fix → summarize_amend → try(push)`

The agent inspects the failing checks and fixes the root cause, then pushes the fix.

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

Validates mergeability, re-runs required graders on the exact PR branch with each grader's `fast` command when configured, then merges. Landing does not run `coverage_analyze` because fast grader variants are pass/fail gates and do not produce the full coverage flow. Transient GitHub errors defer the Job back to `approved` for retry. Does not run `implement` — only landing validation and merge.

## external_pr_merge

**When it fires:** An `external_pr` Job is approved through the landing queue.

**Step chain:** `mergeability_preflight → prepare → grader_fanout → grader_collect → external_pr_merge`

Validates the externally filed PR and merges it through GitHub's merge API. The workflow prepares the workspace before running graders but does not run a normal push step. Same-repository external PRs can run `landing_fix` after grader failures and push repair commits back to the PR head before merge. Fork PRs receive a `REQUEST_CHANGES` review on required grader failure and return to `implemented` for re-approval after the contributor pushes a fix.

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

**When it fires:** Spawned automatically by `MainHealthChangedService` when the repository's main branch is detected as broken (grader health transitions to broken).

**Step chain:** `preflight_grader_fanout → [preflight_grader steps] → preflight_grader_collect → prepare → retry_until(implement, grader_fanout, grader_collect) → summarize → test_plan → pr_open`

The workflow runs a preflight grader check before invoking the agent. If the preflight graders all pass (indicating the broken signal was a false positive), `preflight_grader_collect` cancels the implement chain and the workflow closes immediately — the agent never runs. `after_success` then updates `grader_health` to healthy, calls `MainHealthChangedService.on_health_change!`, and closes the anchor job.

If any required preflight grader fails, the chain continues normally to the implement step. The agent fixes the broken code, graders validate the fix, and a PR is opened. `PollPullRequestJob` calls `MainHealthChangedService.repair_landed!` when the PR merges.

## main_grader

**When it fires:** An internal trigger for running graders against the main branch (used for automated main-branch health checks).

This trigger kind is infrastructure-facing and not surfaced in the operator Job state machine. It does not produce a PR or appear in the normal Job workflow list.

**Workspace lifecycle:** Infrastructure workflows (those in `Workflow::INFRASTRUCTURE_TRIGGER_KINDS`) clean their workspace immediately on both success and failure — they do not participate in the normal failed-workflow workspace retention. This is enforced at two layers:

1. The `fail` AASM event in `Workflow` calls `cleanup_workspace!` immediately for infrastructure workflows.
2. `WorkflowWorkspacePruneJob#db_sweep` and `#filesystem_sweep` apply `RETAIN_AFTER_SUCCESS_OR_CANCEL` (2 hours) as a backstop for infrastructure failed workflows instead of the normal tiered retention logic.

**Normal (non-infrastructure) failed workflow workspace retention:** Syrus keeps at most one workspace per Job on disk at a time. When a new workflow's first run starts, it eagerly sweeps all sibling workflows' workspace directories (`WorkflowWorkspace#sweep_sibling_workspaces!`), stamping `cleaned_up_at` on each so the "Retry from failed step" button is immediately disabled for superseded workflows.

`WorkflowWorkspacePruneJob` applies a three-tier backstop for any workspaces not caught by the eager sweep:

1. **Non-latest workflow:** pruned immediately on the next prune pass. The eager sweep should have handled these; this is the defense-in-depth backstop.
2. **Latest workflow + job is closed:** pruned after `RETAIN_AFTER_SUCCESS_OR_CANCEL` (2 hours). The job is done; no retry is coming.
3. **Latest workflow + job is open:** retained up to `RETAIN_AFTER_FAILURE` (7 days). The operator may still use "Retry from failed step."

Only the Job's latest workflow is eligible for "Retry from failed step" (`Workflow#retry_available?` checks `latest_for_job?`). The `reopen` AASM event also carries this guard, so a superseded workflow cannot be reopened even by direct API calls.

**Retry/Reopen suppression:** Infrastructure Jobs and their anchor workflows are not operator-retryable. The "Retry from failed step", "Retry implementation", and "Reopen" UI actions are suppressed for infrastructure jobs in `App::JobDetailPayload` and `App::JobRetryActions`.
