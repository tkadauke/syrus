# Workflow Trigger Kinds

Every `Workflow` has a `trigger_kind` that identifies what the attempt is for and which step chain it runs. Trigger kinds are defined in `app/models/workflow/trigger_kind.rb`.

## initial

**When it fires:** A new GitHub issue receives the trigger label (or a `direct` or `cron` Job is created).

**Step chain:** `prepare → adversarial_review_loop? → retry_until(implement, graders) → coverage_analyze? → summarize → test_plan → pr_open`

The primary workflow: explores the repo, writes code, runs graders, and opens a PR.

## pr_comment

**When it fires:** New review comments appear on the Job's PR since the last addressed comment.

**Step chain:** `prepare → retry_until(respond, graders) → coverage_analyze? → coverage_pr_comment? → summarize_amend → try(push)`

Addresses review feedback, updates the PR description, and pushes. If the push encounters a non-fast-forward conflict, dynamically inserts an agent-rebase recovery chain.

## chat_feedback

**When it fires:** An operator sends a message in the chat workspace linked to a Job.

**Step chain:** Same as `pr_comment`.

Structurally identical to `pr_comment` but triggered from the chat interface rather than a GitHub review comment.

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

**Step chain:** `mergeability_preflight → prepare → retry_until(graders, repair: landing_fix) → coverage_analyze? → push → auto_merge`

Validates mergeability, re-runs required graders on the exact PR branch, then merges. Transient GitHub errors defer the Job back to `approved` for retry. Does not run `implement` — only landing validation and merge.

## merge_train

**When it fires:** All open child Jobs of an Epic are approved and `AppSetting.merge_train_enabled` is true.

**Step chain:** `merge_train_assemble → merge_train_build → prepare → retry_until(graders, repair: landing_fix) → merge_train_land`

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

**Step chain:** `prepare → grader_fanout → grader_collect → summarize → test_plan → pr_open`

Validates the agent's committed work with graders (no repair loop — graders must pass), then opens the PR. On grader failure, reverts the Job to `:coding` so the agent can fix and re-run. On grader pass, opens the PR and notifies the linked chat.

## local_mode_handoff

**When it fires:** An operator confirms a handoff from a Local Mode chat session (labs feature `local_mode`).

**Step chain:** Similar to `coding_handoff` — runs graders on committed changes and opens the PR.

Like `coding_handoff`, requires operator confirmation before the workflow dispatches.

## main_grader

**When it fires:** An internal trigger for running graders against the main branch (used for automated main-branch health checks).

This trigger kind is infrastructure-facing and not surfaced in the operator Job state machine. It does not produce a PR or appear in the normal Job workflow list.

**Workspace lifecycle:** Infrastructure workflows (those in `Workflow::INFRASTRUCTURE_TRIGGER_KINDS`) clean their workspace immediately on both success and failure — they do not hold the workspace for the 7-day "Retry from failed step" window that normal failed workflows retain. This is enforced at two layers:

1. The `fail` AASM event in `Workflow` calls `cleanup_workspace!` immediately for infrastructure workflows.
2. `WorkflowWorkspacePruneJob#db_sweep` and `#filesystem_sweep` apply `RETAIN_AFTER_SUCCESS_OR_CANCEL` (2 hours) as a backstop for infrastructure failed workflows instead of the normal `RETAIN_AFTER_FAILURE` (7 days).

**Retry/Reopen suppression:** Infrastructure Jobs and their anchor workflows are not operator-retryable. The "Retry from failed step", "Retry implementation", and "Reopen" UI actions are suppressed for infrastructure jobs in `App::JobDetailPayload` and `App::JobRetryActions`.
