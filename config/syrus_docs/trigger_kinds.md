# Workflow Trigger Kinds

Every `Workflow` has a `trigger_kind` that identifies what the attempt is for and which step chain it runs. Trigger kinds are defined in `app/models/workflow/trigger_kind.rb`.

## initial

**When it fires:** A new GitHub issue receives the trigger label (or a `direct` or `cron` Job is created).

**Step chain:** `prepare → implement → adversarial_review_loop? → visual_review_loop? → retry_until(format/generate/graders, repair: implement) → coverage_analyze? → dependency_audit → summarize → test_plan → pr_open`

The primary workflow: explores the repo, writes code, runs graders, and opens a PR.

## unland

**When it fires:** An operator confirms a compensating rollback for a
successfully landed Job or Epic. Unlanding is experimental and off by default;
an admin must enable the `unlanding` feature flag before new unland operations
can be previewed or confirmed. Disabling it later blocks only new operations —
existing rollback Jobs and unland Workflows keep running and stay visible.

**Step chain:** `unland_revert → unland_conflict? → prepare → grader_fanout → grader_collect → summarize → pr_open`

Syrus first produces an operator-readable preflight plan listing the affected
Job/Epic records, exact ordered commits, changed files, downstream dependents,
deployment-stage reach, selected fast graders, and warnings. For an Epic, merge-train membership or
the child dependency order bounds the commit set; shared ownership, partial
landing, and previously reverted children block creation. Once confirmed,
Syrus creates one linked rollback Job and one revert PR while leaving every
original Job's closed state, closure reason, landed SHA, and dependency graph
intact. It verifies recorded landing evidence against current default-branch ancestry,
reverts them in reverse order from the current default tip, and invokes the
implementing agent only for conflicts. The proposed tree uses only graders
explicitly configured with `phases: [unland]`; after changed-file filtering it
fails unless at least one required grader was selected. A successful attempt
opens an ordinary PR. Approval and landing remain normal, except final landing
validation also uses `unland` and therefore cannot silently expand to the full
landing suite.

The original detail and timeline remain the audit record: they distinguish a
landed record, an active or failed unland, and a successfully reverted landing,
and link to the rollback Job and PR. A Git revert does not roll back a deployed
environment; use the deployment system's recovery procedure separately. If an
attempt fails, inspect or retry the linked rollback Job. To reapply later,
create normal reviewed work from the desired reverted changes instead of
reopening or rewriting the original record.

## skill

**When it fires:** A `direct` Job is created with `skill_name` + `skill_args` set (`SkillJobs::Creator`), rather than a free-form prompt.

**Step chain:** `prepare → run_skill → retry_until(run_skill, graders) → summarize → pr_open`

`run_skill` resolves the named skill via `Skills.for` (a repo-local
`.syrus/skills/<name>/SKILL.md` override, or a built-in skill),
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

## investigation

Investigation Jobs perform read-only analysis and report findings; they do not open a PR or enter the landing queue. The agent may propose follow-up Jobs during the investigation and submits its report separately. Proposed follow-ups remain in triage until an operator accepts or rejects them. Accepting creates the normal initial workflow; rejecting closes the proposal without counting it as delivered work.

Investigation attempts are bounded and must use the repository's available tools and credentials. Failures remain visible for retry or operator review. An investigation can be closed when its report is accepted even if no follow-up work is proposed.

## pr_comment

**When it fires:** New non-Syrus-bot review comments appear on the Job's PR since the last addressed comment.

**Step chain:** `prepare → retry_until(respond, graders) → coverage_analyze? → coverage_pr_comment? → summarize_amend → refresh_job_metadata → try(push)`

Addresses review feedback, produces revision-scoped commit copy, optionally refreshes canonical Job/PR metadata when feedback changed the effective intent, and pushes. Comments authored by the configured Syrus GitHub App bot are ignored so automated comments such as coverage reports do not self-trigger feedback workflows. Syrus records which `PrReviewComment` rows a workflow is handling, marks them handled only after the workflow succeeds, and leaves failed or rate-limited handling visible on the Job detail pending-feedback panel for manual retry. If the push encounters a non-fast-forward conflict, dynamically inserts an agent-rebase recovery chain.

## chat_feedback

**When it fires:** An operator sends a message in the chat workspace linked to a Job.

**Step chain:** Same as `pr_comment`.

Structurally identical to `pr_comment` but triggered from the chat interface rather than a GitHub review comment. Confirmed feedback is rejected only when another `chat_feedback` workflow is already queued or running for the Job; unrelated active work such as visual review leaves the feedback workflow queued behind the active Job lock. When chat feedback originated from a pending PR comment, the source comment is tied to the workflow and becomes retryable from the pending-feedback panel if handling fails before success.

## ci_failure

**When it fires:** CI checks on the Job's PR fail and the job is configured for CI repair.

**Step chain:** `prepare → retry_until(analyze_and_fix, graders) → summarize_amend → try(push)`

The agent inspects the failing checks and fixes the root cause, then Syrus runs
the repository's configured `ci` phase graders before pushing the fix. Put
CI-only checks in explicit `.syrus.yml` graders with `phases: [ci]` so the
agent can verify that the GitHub CI failure is actually fixed. If graders fail,
their output feeds the next `analyze_and_fix` iteration.

Repository owners and admins can disable automatic pull-request CI repair in
repository settings. Polling continues to cache check state for landing gates,
but it does not dispatch new `ci_failure` workflows; already-queued repairs wait
with `ci_repair_disabled`. An operator-initiated manual poll or repair overrides
the setting.

The failed GitHub checks are mapped to their covering graders by explicit
`ci_checks` metadata, target label, or matching grader/check names. Once every
covering grader passes and the branch contains commits after the PR head that
started the workflow, Syrus continues to `summarize_amend`/`push`. Other red
required CI-phase graders are recorded as advisory evidence, including their
base-retry result when available, rather than discarding the focused fix.

A later `analyze_and_fix` iteration that makes no new diff also preserves an
earlier committed fix for grading and push. A no-diff iteration still fails
with `agent_outcome: "no_changes_produced"` when the branch has no commit after
the original head. If it repeats a prior `report_main_concern` diagnosis for
the same observed main SHA, failing grader, and reason, Syrus instead records
`blocked_by_main`, skips that iteration's pending grader check steps, and
continues to `summarize_amend`/`push`. This avoids burning the full retry budget
against a self-diagnosed pre-existing main failure.

`PollPullRequestJob#react_to_ci_failures` skips dispatch entirely — without
spending any of the Job's `CI_FAILURE_CAP` budget — while the repository's
main branch is known-broken (`repository.landing_paused? && repository.main_health_broken?`,
the same condition `StepDispatcher` already uses to hold workflow starts). This
avoids blaming the Job's own diff for a red check caused by a broken base
revision. `main_branch_repair` Jobs are exempt from this guard the same way
they're exempt from the `ci_failure` cap, since a repair job must keep
absorbing CI feedback until main is actually fixed. See `main_branch_repair`
below for what happens to PRs deferred this way once main recovers.

The workflow start gate applies the same introduced-failure rule as the
poller: when the base is not known healthy, repair may still start if the PR
has a failing check absent from the base's recorded failures. It remains
blocked when every failure is inherited or there is no base failure evidence.
For stacked Jobs, the gate consults the parent PR's recorded failing names
before falling back to the repository's newest main-branch health record.

## retry

**When it fires:** Operator triggers a retry of a failed Job from the UI or admin API.

**Step chain:** Same quality gates as `initial`, but with `implement` inside the adversarial review loop when configured: `prepare → adversarial_review_loop? → visual_review_loop? → retry_until(implement, format/generate/graders) → coverage_analyze? → dependency_audit → summarize → test_plan → pr_open`.

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

**When it fires:** All open child Jobs of an Epic are approved.

**Step chain:** `merge_train_assemble → merge_train_build → merge_train_reconcile → prepare → retry_until(graders, repair: landing_fix) → merge_train_land`

Atomically lands all Epic child PRs through a single integration branch. If the
base branch moves during landing, the workflow dynamically inserts
`merge_train_rebase → merge_train_agent_rebase → retry_until(graders, repair:
landing_fix) → merge_train_land_after_rebase`; the agentic rebase step is
skipped when the deterministic rebase succeeds cleanly. See the Merge Train
documentation for details.

## rebase

**When it fires:** `PollAllMergeStatesJob` detects that the Job's PR branch is `mergeable: false` and Syrus controls the head branch.

**Step chain:** `auto_rebase → agent_rebase → force_push`

Rebases the PR branch onto the base branch. Skips `commit_agent_changes` (rebase rewrites history). Uses `--force-with-lease` to prevent clobbering concurrent pushes. Closed-preempted Jobs remain in the rebase poll scope while their external PR is open.

## base_refresh_retry

Restores a selected failed Workflow's latest published mutation checkpoint into
a new Workflow, records the current effective base ref and SHA, and resolves
that ref again immediately before rebasing the checkpoint. This allows a
queued or retried refresh to follow an advancing base while still detecting a
base move between the final resolve and fetch. Clean rebases skip agent repair;
conflicts use the existing bounded agentic rebase machinery. The refreshed
source is published immutably, then setup, graders, and the normal
PR-publication tail run without a redundant initial implementation pass.
Missing checkpoints and concurrent mutation work fail safely. The
operator-confirmed `retry_job` chat tool starts this mode with
`mode: refresh_base` and an audit reason; the older dedicated
`base_refresh_retry_job` entry point remains compatible. Ordinary same-snapshot
retries are unchanged.

## stack_rebase

**When it fires:** A dependent PR stack needs rebasing due to base-branch advancement.

**Step chain:** `stack_auto_rebase → stack_agent_rebase → stack_force_push`

Rebases a chain of dependent PR branches in dependency order, then resumes landing for any approved stack Jobs.

`stack_rebase` is an Epic-wide workflow when the Job belongs to an Epic. With
early Epic dependency execution enabled, an anchored same-repository linear
dependency chain is traversed across Epic boundaries and each newly rebased
tail becomes the next Epic root's base. The workflow locks every participating
Job and Epic, blocking ordinary child workflows, downstream restacks, and
merge trains while branches are being force-pushed.

## coding_handoff

Created when an operator confirms submission of Coding Mode changes. Syrus captures the committed checkout, validates that it belongs to the expected repository and base, and creates or updates the implementation Job. It then runs the normal format, generate, grader, review, summary, push, and PR flow as configured.

Repeated submission is idempotent for the same captured change. Empty or unverifiable handoffs are refused. Stack-aware handoffs preserve their declared parent/base relationship, and subsequent feedback or rebases use the ordinary Job workflow behavior.

## local_mode_handoff

**When it fires:** An operator confirms a handoff from a Local Mode chat session (labs feature `local_mode`).

**Step chain:** When no PR exists: `prepare → retry_until(grader_fanout → grader_collect, repair: local_mode_handoff_fix) → summarize → test_plan → pr_open`. When a PR already exists (taken-over implemented Job): `prepare → retry_until(grader_fanout → grader_collect, repair: local_mode_handoff_fix) → summarize_amend → try(push)`.

Requires operator confirmation before the workflow dispatches. The linked chat
stays attached while graders run and is cleared only after the local-mode
handoff succeeds.

**On grader failure:** Graders run inside a retry loop repaired by `local_mode_handoff_fix`, so workflow agents own repair instead of the originating Local Mode chat. If the retry budget is exhausted, `after_fail` posts a passive grader report to the linked chat when one is still available and marks the Job failed so the normal Retry path is available. It does not enqueue or promote a chat-agent turn, and it does not return the Job to `:coding`.

**On non-grader failure** (e.g. `prepare` failed): `after_fail` drives the Job to `:failed` manually so the operator has the normal Retry path.

## main_branch_repair

When the default branch is unhealthy, Syrus can create an infrastructure repair Job that checks out the failing revision, attempts a bounded repair, validates it, and opens the normal reviewed change. Repository landing is held while main is known broken and resumes when health becomes healthy or inconclusive according to policy.

Only one active repair is maintained for the same repository health episode. Polling retries transient GitHub failures without treating missing data as healthy; sustained inability to inspect an already-broken branch makes health inconclusive so the outage does not freeze landing forever. Recovery work is rate-limited to avoid a burst after a broad outage.

Infrastructure workflow workspaces are cleaned after either success or failure. They are not operator-retryable through ordinary Job retry/reopen actions; a new health evaluation creates the appropriate recovery attempt.

## main_grader

A main-grader workflow checks the repository default branch with configured CI-phase graders and target-health rules. It records healthy, broken, inconclusive, or not-configured health and updates landing gates accordingly. Healthy reusable target evidence may avoid redundant work; stale, missing, or unhealthy evidence runs fresh validation.

Main-grader work is infrastructure work: it is rate-limited, cleans its workspace after success or failure, and is not exposed through ordinary Job retry or reopen actions. Transient GitHub inspection failures retry on the next poll and never fabricate a healthy result from missing data.
