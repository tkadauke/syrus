# Findings ledger

One entry per finding from the Lean bug hunt. Verdicts:

- **fixed** — reproduced by a failing Ruby spec, fixed, spec green, Lean model updated.
- **by design** — the counterexample describes intended behavior; the model now says so.
- **open** — reproduced or suspected, waiting for a decision.
- **model** — the model was wrong; nothing in Ruby changed.

Evidence notes record where the claim came from (model, code reading,
production telemetry via the read-only admin API).

---

## F1. Reconciler and JobWakeup fight over dependency waits — fixed

**Property.** The reconciler never "repairs" a state the domain logic
deliberately produces (`Agreement.Agrees`), so the two controllers converge.

**Counterexample.** `Agreement.before_oscillates`: an intent `waiting` on an
unsatisfied dependency, with an active WorkUnit. `classify_waiting_work_intents_with_active_units`
calls `request!`; the next `JobWakeup` → `Scheduler.evaluate!` parks it
`waiting` again. Forever.

**Evidence.** Production, ~9 hours of `repair_executed` events: 2,801 applied
`clear_waiting_work_intent_active_unit` repairs — 70% of all repairs. The same
ten intents were each re-detected ~100 times over 90 minutes, every one with
`wait_reason: dependency`. The Job page shows the intent's wait reason, so it
flickered on and off.

**Which side was wrong.** The reconciler. `JobWakeup` parking the intent while
the Launcher's unit exists is asserted by `job_wakeup_spec.rb`;
`WorkUnit#reactivate_work_intent!` treats `waiting` as compatible with an active
unit; the Job page serializer renders it. Only a *stale* wait (gates now pass)
is abnormal.

**Fix.** The classifier and the executor policy skip waits whose intent gates
still fail.

**Proofs.** `after_agrees`, `after_commutes`, `after_converges` (any interleaving
of wakeups and reconciles is stable after one wakeup), `after_clears_stale`,
`after_keeps_justified`.

**Spec.** `reconciler_spec.rb` — "leaves a justified dependency wait alone when
the intent already has an active WorkUnit" (red before, green after).

**Review note.** Expect `waiting_work_intent_with_active_unit` to all but vanish
from reconciler activity after deploy.

---

## F2. Artifact saves revert concurrent writes (lost update) — fixed

**Property.** A key the caller did not change keeps whatever a concurrent
writer stored (`Artifacts.delta_preserves_concurrent`); the caller's own edits
still land (`delta_applies_changes`).

**Counterexample.** `Artifacts.whole_loses_update`. Two shapes in Ruby:
1. `WorkUnits::WorkflowCancellation#cancel!` snapshotted the whole bag *before*
   taking the Workflow lock and merged it over the reloaded bag *inside* the
   lock, so any `set_artifact!` in between was reverted.
2. Systemic: `Workflow#persist_assigned_external_artifacts` wrote back every
   staged key, so *any* `workflow.artifacts = workflow.artifacts.merge(...)` +
   save on an instance loaded before another writer's `set_artifact!` reverted
   it. Roughly three dozen call sites assign the bag without a lock.

**Fix.** New `Workflow#staged_artifact_changes` (staged keys whose value differs
from the value as read from the database — `attribute_in_database`, so in-place
mutation of a loaded hash still counts as a change). The persist hook writes
only those; `cancel!` carries only those across its reload. One fix covers all
bag-assignment call sites.

**Specs.** `workflow_spec.rb` "does not revert a key another writer changed after
the instance loaded" (red before), "persists a loaded value the caller mutated
in place before reassigning" (guards the obvious regression);
`workflow_cancellation_spec.rb` "does not revert an artifact another writer set
after the caller loaded the Workflow" (red before), "keeps artifacts the caller
staged on its instance but had not saved".

**Review note.** Deletions (keys omitted from an assigned bag) still delete
whatever the instance observed; not changed and not modelled.

---

## F3. A RunJob waiting on its concurrency semaphore was called orphaned — fixed

**Property.** The reconciler flags a queued Run's SolidQueue job as orphaned
exactly when it has no execution row (`QueueExecution.after_exact`).

**Counterexample.** `before_misclassifies_blocked`. `RunJob` is
`limits_concurrency to: 1` per Job, so a second Run's job sits in
`solid_queue_blocked_executions`. The snapshot never loaded blocked executions,
so after two minutes the job read as orphaned; the repair deleted and
re-enqueued it, where it blocked again.

**Evidence.** `queued_run_with_orphaned_queue_job → reenqueue_run` was the most
frequent *applied* Run repair in production (78 in ~9h). Not confirmed per-job
that these were blocked executions — no read access to the queue tables.

**Fix.** Load blocked executions into the snapshot; blocked counts as able to
progress (SolidQueue's dispatcher promotes it, and its concurrency maintenance
expires semaphores held by dead claims) and is never orphaned.

**Spec.** `reconciler_spec.rb` "does not treat a RunJob blocked on its
concurrency semaphore as orphaned".

**Review note.** Watch the `queued_run_with_orphaned_queue_job` rate after
deploy; the real 12.5-hour orphan from the original incident is still caught.

---

## F4. Retry planned for failed Runs of still-running Workflows — fixed

**Property.** A classifier fires only where some repair it plans can execute
(`Agreement.Actionable`).

**Counterexample.** `retry_before_not_actionable`. `classify_retryable_failures`
flagged any failed Run controlling its Step; every repair the planner can pick
for it refuses an active Workflow (`RetryFailedStepEnqueuer` needs
`workflow.failed?`; `ResumeWorkflowEnqueuer` refuses active runtime work;
whole-Workflow retry needs a finished Workflow and no active work).

**Evidence.** 168 skipped `rebuild_merge_train` in ~9h on two merge trains, all
"Workflow is not in a failed state." One ran its grade loop for 5.5h with three
failed graders and then *succeeded*; the reconciler planned a refused rebuild on
every pass in between.

**Fix.** Skip the classifier while the Run's Workflow is queued or running.
Behavior once the Workflow is finished is unchanged
(`retry_after_complete_on_finished`).

**Spec.** `reconciler_spec.rb` "does not plan a retry for a failed Run while its
Workflow is still running" (red before).

**Related, not yet worked.** The same agreement check should be applied
systematically: 522 skipped `resume_queued_step` ("queued Step remained
deferred", one Workflow) and 204 skipped `start_workflow` ("workflow start
remained blocked") look like the same shape but may be intended "nudge" repairs.

---

## F5. Stacked Epic members rebased right after their train landed them — fixed

**Evidence.** Production: an Epic merge train succeeded; 19s later a `rebase`
Workflow was created for a member; 2.7s after that the PR poller closed the
member as `pr_merged`; the rebase *started* after the close and had a
`force_push` queued when the reconciler cancelled it.

**Cause.** `Job#rebase_stack_children_after_successful_parent_close` →
`StackRebaseCoordinator.parent_merged` rebases open stack children when a parent
closes as merged. A train lands the whole stack, so each child is still open for
a few seconds after its parent closes; the coordinator's guards ("child closed?",
"merge train active?") both miss.

**Fix.** Skip a child merged (`MergeTrainMember` state `merged`) by the same
train that merged its parent. A child landed only by an earlier train is still
rebased.

**Specs.** `stack_rebase_coordinator_spec.rb` "does not rebase a child that
landed in the same merge train as its parent" (red before), "still rebases a
child whose earlier train landed it but not with this parent".

**Lean.** None: a single direct guard, a theorem would restate it. The general
property it serves — no Run starts for a closed Job — is F6.

---

## F6. Workflows kept running on closed Jobs — fixed (operator-approved design)

**Property.** No active runtime Workflow works on a closed Job
(`JobClosure.ClosedQuiet`), and every closure a Workflow requests is applied
when it finishes (`finish_honors_pending`). `plainClose_breaks`: closing without
cancelling the Job's other Workflows violates it.

**Evidence.** The F5 timeline (rebase started after its Job closed);
`closed_job_active_runtime_work` repairs in production.

**Design (decided in review).** A Workflow never closes a Job while running:
- Steps call `Workflow#request_job_closure!(job, reason)` (pending closure on
  the Workflow). Migrated: `auto_merge`, `merge_train_land` (member Jobs),
  `stack_auto_rebase`, `auto_rebase`, `external_pr_merge`, `mergeability_preflight`,
  `pr_open` (no_changes), `promotion_publish`, `hotfix_sync_publish`,
  `upstream_export_publish`, `auto_close`.
- When the Workflow's *own* Job has a pending closure, the dispatcher skips the
  remaining queued steps and finishes — the close is always the final act.
- `Workflows::LifecyclePropagation` applies pending closures on every terminal
  outcome (succeeded/failed/cancelled/blocked), before Job propagation.
- `JobClosure.close_now!` cancels the Job's other active Workflows, then closes.
- External closers (`PullRequestMergeCloser`, `PollPullRequestJob`,
  `PollExternalPrJob`, `GracePeriodExpiryJob`) use `JobClosure.request!`: defer
  to an active landing Workflow that owns the Job (e.g. a train landing its
  members), otherwise close now. Branch deletion only when closed now.
- Backstop: the dispatcher never starts a next step, and `RunJob` never runs a
  step, for a closed Job (same deploy exception as the existing start guard).

**Bugs found while building it (both covered by specs).**
- A cached `workflow.job` still in its pre-close state made success
  propagation save `implemented` over the close; `apply_pending!` reloads it.
- `Job#active_runtime_workflows` runs `TerminalWorkflowSync` first; mid-cancel
  that re-cancelled the finishing Workflow and recursed. `close_now!` queries
  ownership directly.
- A Workflow ended early by its own closure is exempt from "PR publication
  missing after success".

**Specs.** `job_closure_spec.rb` (6: early finish + close, close on failure,
no next step after an external close, `close_now!` cancels others, deferral to
a landing owner, close now otherwise); step specs now assert the pending closure
and the close on finish (`auto_merge` additionally that the Job stays `landing`
until then).

**Review notes.**
- Behavior change: Jobs closed by landing steps now close a moment later (at
  Workflow finish) instead of mid-step. A merge train's members all close when
  the train finishes, not one by one as it lands them.
- Other plain `close_with_reason!` callers outside Workflows (operator cancel,
  Epic archive, too-many-failures, ingestion, plugins' after-success hooks) are
  unchanged; the step-boundary and `RunJob` backstops cover them.

---

## F7. A landing that cannot place a step fails and is held — fixed (operator-approved design, was Q1)

**Property.** Running ⇔ holding the landing slot (`LandingSlot.SlotExact`),
preserved by launch, fail and finish; the slot is free as soon as a landing
cannot proceed (`cannotPlace_frees_slot`); a held landing is not re-launched
while no capable worker is live (`held_not_relaunched`). `parkSurrendering_breaks`:
the old park-and-surrender let a second landing run alongside one still in flight.

**Design (decided in review).**
- `StepDispatcher.capability_worker_deferred?`: when the step belongs to a
  landing Workflow, record a `LandingCapabilityHold` (queue + requirements from
  the resolver's Decision) and fail the landing with a `no_capable_worker: …`
  reason instead of recording a start block. Applies before and after the first
  Run, so the landing never parks in flight.
- New `LandingFailureCode::NoCapableWorker`: defers landing (the Job stays
  `approved`, approval kept) and skips the time-based train cooldown.
- The hold gates re-launch: `LandingQueueProcessor#blockage_for` reports
  `waiting_for_capable_worker` (en/de/la), `MergeTrainDispatcher#blocker_reason`
  refuses the Epic's next train. The hold releases itself once
  `RunQueueResolver.live_capable_worker?` sees a matching live worker; any later
  landing attempt supersedes it.

**Specs.** `landing_capability_hold_spec.rb` (fail + hold + Job stays approved
with the code; release when a capable worker heartbeats; superseded by a later
attempt; train dispatcher refuses a held Epic); `landing_queue_processor_spec.rb`
"does not re-launch a landing held for a capable worker until one is live".

**Caught while building it.** The hold check ran one Workflow query per queue
entry and broke the landing queue's no-N+1 guard; it is now gated on the Job's
`landing_failure_code` column.

**Not done — "ideally never start a landing without a capable worker".** The
first attempt still starts and fails fast at the first step no live worker can
run (then the hold prevents repeats). A true pre-launch check needs every step's
requirements before the landing is instantiated (grader targets are materialized
during fanout), which is a larger change. Worth an explicit follow-up.

---

## F8. Linear Epic children could implement in parallel — fixed

**Property.** At most one child of a linear Epic has a running implementation
Workflow (`EpicTurn.fixed_preserves_one_running`, every Epic up to 4 children).

**Counterexamples.**
- `retry_bypass`: the turn rule ran only in `start_workflow`. A failed child
  does not hold the turn, so the next sibling may start; `RetryFailedStepEnqueuer`
  then reopened the failed Workflow and created its Run directly.
- `two_query_race`: `epic_sibling_blocking?` asked "is a sibling running?" and
  "who is the oldest queued?" in two queries; a sibling whose RunJob flipped it
  to running in between was in neither answer.

**Fix.** The rule reads one snapshot of the Epic's queued/running
implementation Workflows. Step retries refuse (as an `active_work_lock`, so
auto-retry reschedules) while a sibling implements.

**Specs.** `step_dispatcher_spec.rb` "keeps the turn when the winning sibling
starts running between the turn's reads" and "does not retry a failed child's
step while a sibling is implementing" (both red before).

---

## F9. Auto-approval approved Jobs before they had a PR — fixed

**Property.** An approved Job has a pull request
(`AutoApproval.new_approved_has_pr`, all operation sequences up to 6), and a
Job whose graders passed is still approved once its PR exists
(`new_still_approves`).

**Counterexample.** `old_strands`: `grader_collect` succeeds (the initial
Workflow grades before `pr_open`) → the rule marks the Job implemented and
approves it → `pr_open` fails → `JobLifecyclePropagation#fail!` skips the
approved Job. Approved, no PR, nothing working on it; the landing queue holds it
as `missing_pull_request` indefinitely (`approved_job_missing_pr` in the
reconciler).

**Fix.** `AutoApprovalRule#approve_after_grader_success!` declines with
`pull_request_missing` when the Job has no PR; `JobLifecyclePropagation#succeed!`
re-evaluates the rule from the Workflow's passing grader Step after marking the
Job implemented.

**Specs.** `auto_approval_rule_spec.rb` "does not approve a Job that has no
pull request yet" (red before) and "approves when the initial Workflow succeeds
after opening the pull request".

**Review note.** Auto-approved Jobs now become approved when the initial
Workflow finishes, not at the moment graders pass.

---

## F10. Cancelling an old Workflow failed a Job a newer one was running — fixed

**Property.** Only the Job's current attempt decides its state: a Workflow's
terminal outcome never fails a Job a newer Workflow still works on
(`JobAttempt.older_outcome_keeps_job`).

**Counterexample.** `old_cancel_fails_worked_job`. `JobLifecyclePropagation#fail!`
returns when a newer Workflow is active; `#cancel!` did not, so any
non-superseding cancel of an older Workflow marked the running Job failed.
Job-scoped work cannot overlap (the WorkUnit lock); Epic-scoped Workflows that
use the Job as their representative can.

**Fix.** `cancel!` applies the same `newer_active_workflow?` guard.

**Specs.** `job_lifecycle_propagation_spec.rb` "does not fail the Job when an
older Workflow is cancelled while a newer one works on it" (red before), "still
fails the Job when its only Workflow is cancelled".

---

## F11. Merge trains could mark members merged without evidence — fixed

**Property.** A member is marked merged (and its Job closed) only with an
integration SHA and evidence its work reached it
(`TrainEvidence.after_merged_has_evidence`).

**Counterexample.** `before_merges_without_evidence`: `reconcile_members!`
verified members only `if integration_sha.present?`. A GitHub merge response
without a SHA skipped verification for every member.

**Fix.** Read the merge commit from the merged PR when the response omits it;
with no SHA at all, every member is unverified (re-landing; the already-on-base
path settles work that did land).

**Specs.** `merge_train_steps_spec.rb` "does not mark members merged when
GitHub's merge response carries no SHA" (red before), "reads the merge commit
from the merged PR when the merge response omits it".

**Review note.** The default merge stubs in that spec returned no SHA, so many
landing specs passed only because verification never ran; one asserted that a
member with no recorded commit lands. They now use a realistic SHA, and that
test records the member's commit.

---

## F12. A stopped landing could still merge — fixed

**Property.** A merge request is only sent while the landing's Run is active;
the unsafe window is the single API request (`MergeFence.after_merge_only_while_active`).

**Counterexample.** `before_merges_after_cancel` / `before_window_is_wider`:
`auto_merge` (and every other merging step) evaluated its gate, spent seconds on
mergeability settling, approval mirroring and validation parity, then merged
without looking again. Stop Landing or a Job closure cancelling the Run in that
window did not stop the merge.

**Fix.** `ensure_run_still_active!("merge")` immediately before each merge
request in `auto_merge`, `merge_train_land`, `external_pr_merge`,
`promotion_publish` and `hotfix_sync_publish`.

**Spec.** `auto_merge_spec.rb` "does not merge when the landing was stopped
after the gate passed" (red before).

**Review note.** A merge train stopped this way can be left `landing` with its
integration PR open; `stale_active_merge_train_without_runtime` repairs that.

---

## F13. Lock acquisition could succeed without a lock row — fixed

**Property.** Acquisition reports success only when the unit holds the key;
anything else is a `LockConflict` (`LockAcquire.new_sound`).

**Counterexample.** `old_silent_no_lock`: our insert hits the unique index, the
holder then releases the key, and the owner lookup finds nobody.
`WorkUnit#ensure_active_locks!` and `Launcher#create_lock!` returned as if they
had acquired it, so `mark_running!` ran the unit without its lock and the free
key could go to a third unit — breaking `LockSafety.HoldsOwnLocks`.

**Fix.** After a violation with no owner, retry the insert once; then fail
closed with `LockConflict`.

**Spec.** `work_unit_spec.rb` "acquires its runtime lock when the previous owner
released it mid-insert" (red before: running with no active lock).

---

## F14. The reconciler cancelled running work for feedback queued behind it — fixed

**Property.** A Workflow waiting behind the Job lock never causes the Workflow
it waits for to be cancelled (`SupersededWork.after_waiters_never_supersede`).

**Counterexample.** `before_cancels_running`: ChatFeedback, Rebase and
StackRebase materialize behind the Job lock (`materialize_behind_active_lock?`).
`classify_superseded_active_runtime_work` saw two active Workflows, kept the
newest — the queued feedback — and auto-repaired by cancelling the running
implementation. The executor re-checks activity, Job and age, none of which
exclude this case.

**Fix.** A queued Workflow of a materialize-behind kind is excluded from the
classifier, alongside the existing patient-rebase exemption.

**Spec.** `reconciler_spec.rb` "does not cancel a running Workflow for feedback
queued behind its Job lock" (red before).

---

## M1. Required reviews vs. the HEAD that is pushed — modelled, awaiting NY1

`ReviewBarrier.lean`. Proved: if every HEAD move is a tracked `implement`/
`respond` step, whatever the barrier lets through was approved
(`tracked_only_push_reviewed`). Counterexamples: `mechanical_after_review`
(format/generate after approval — pushed unreviewed, barrier passes) and
`agent_untracked_after_review` (landing_fix / agent rebase — not even the last
agent-authored commit was reviewed). The blank-SHA fail-open only matters
combined with an untracked move (`vacuous_barrier_with_untracked`). No code bug
in the tracked path: both agentic success paths record `head_sha`. Policy
question NY1 on the coverage page.

---

## M2. The serial barrier in the distributed ready set — proved (bounded)

`ReadySet.lean` mirrors `StepDispatcher#distributed_ready_set`. Exhaustive
check over every Workflow of up to 5 Steps: starting what the scan picks never
starts a Step after an unfinished serial Step (`readySet_preserves_barrier`), so
at most one serial Step runs (`barrier_one_serial`). The cursor
(`position > from_step.position`) is load-bearing (`cursor_needed`); every
caller advances from a just-finished Step. Consequence for the review barrier:
a Run can only become stale while queued, where `RunJob` cancels it. No bug
found. Unmodelled: Step insertion (review re-materialization, grader fan-out),
`skippable_queued_step?`, retry reopening.

---

## Open questions for review

- **Q1 — resolved as F7** (fail and hold instead of parking).
- **Q2 — resolved as F5 + F6** (no rebase for children landed with their
  parent; deferred closure, no step starts for a closed Job).
- **Q3. Admin WorkUnits list 500s past page 29** (`Mysql2: Out of sort memory`)
  — found while paging it read-only for O1; not engine-related.

## Pre-existing failures to fix

- `spec/jobs/run_job_parallel_grader_projection_spec.rb:55` (ci_only) fails
  locally: after `grader_fanout` runs, the materialized grader Steps have no
  Runs (`step.runs.sole` raises). Reproduced with every app file this work
  touched restored to the pre-session main commit, so it predates these
  changes. Not yet known whether it also fails in CI or only on this machine
  (the spec drives real git over `file://` remotes).

## Leads not yet worked (from the catalog)

- `approved`/`implemented` Job without a PR: approve guard is `true`, and
  auto-approval fires on `grader_collect` success before `pr_open`.
- `stranded_landing_job` / `landing_work_job_state_drift`: two definitions of
  "active landing work" (`RuntimeOwnership.active_landing_work?` vs the
  reconciler's) can push a Job back into `landing` after the repair deferred it.
- Classifier ⇔ executor disagreement loops: 522 skipped `resume_queued_step` on
  one Workflow, 204 skipped `start_workflow`, 168 skipped `rebuild_merge_train`
  ("Workflow is not in a failed state") in ~9h.
- `git_transport_transient` in-place retries are not exempted like
  `worker_died`, so the Step may be reconciled to failed during backoff.
- Two definitions of "active Step" (projected vs stored) between the reconciler
  and `StepDispatcher#finish_workflow!`.
- `JobLifecyclePropagation#cancel!` lacks the newer-active-workflow guard that
  `fail!` has.
- Required-review barrier only treats `implement`/`respond` as moving HEAD.

## Low / by design

- **D2.** `AutoRetryBackoff#record!` blocks a `failed` unit and re-takes its
  locks: same-attempt retry reuses the unit (see D1). Its "any active lock ⇒
  done" shortcut can leave a partial lock set, but every resume path re-runs
  `ensure_active_locks!`.

---

## Carried over from the first model round

- **O1. One WorkUnit per Workflow is assumed, not enforced** — open.
  `LockSafety.steps_lock_safe` needs it; `Examples.shared` shows lock escape
  without it. No unique index on `work_units.workflow_id`.
- **O2. Intent-scoped relaunch classifiers are unreachable in production** —
  open. No caller passes `work_intent:` to `Reconciler.request`.
- **O3. Mixed succeeded/failed units: success wins regardless of recency** —
  open, low.
- **D1. Finished WorkUnits are re-entrant** — by design (retries reuse the unit).
