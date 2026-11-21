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

## F15. A step retry could give a Step a second active Run — fixed

**Property.** A Step has at most one active Run
(`StepRuns.new_at_most_one`, every interleaving of up to 6 operations).

**Counterexample.** `old_two_active`: a Step is marked failed while its Run is
still live; `RetryFailedStepEnqueuer` reopens it and creates another Run. The
dispatcher's creator holds the Step lock and checks for an active Run; the retry
creator did neither (no database constraint backs the rule).

**Fix.** The retry refuses while the Step has an active Run, and creates its Run
under the Step's row lock, reusing one the dispatcher already started.

**Spec.** `retry_failed_step_enqueuer_spec.rb` "does not add a second active Run
to a failed Step whose Run is still live" (red before).

---

## F16. A paused phase was "repaired" on every reconcile pass — fixed

**Property.** Classifier ⇒ executable repair (`Agreement.Actionable`;
`resume_before_not_actionable`, `resume_after_actionable`).

**Evidence.** The 534 skipped `resume_queued_step` repairs in the production
sample were a single rebase Workflow whose WorkUnit an operator had paused
(`manual_pause`) right before `force_push`, three weeks earlier.
`classify_queued_steps_without_runs` flagged the held Step every pass; the
resume refused every time with the uninformative "queued Step remained
deferred".

**Fix.** Steps whose WorkUnit is blocked on a pause reason (`manual_pause`,
`provider_availability`) are not flagged. The executor's skip message now names
the resume's status and reason.

**Spec.** `reconciler_spec.rb` "does not flag a queued Step held by a manual
pause" (red before).

**Review note.** That Workflow is still paused in production on a failed Job;
it needs an operator decision (resume or cancel), not a code change.

---

## F17. The reconciler kept starting stack-blocked Workflows the dispatcher refused — fixed

**Property.** The reconciler's "stale start block" uses the dispatcher's own
readiness rule (`Agreement.stack_after_actionable`).

**Evidence.** The 204 refused `start_workflow` repairs in the production sample
were legitimately blocked Workflows: three on `stack_dependencies_not_ready`,
two on the Epic turn.

**Counterexample.** `stack_before_not_actionable`: the dispatcher sets the stack
block from `JobStackResolver`; the reconciler (`current_start_block_active?`,
`stale_dependency_start_block?`) judged it from
`dependencies_satisfied_for_execution?`. A same-Epic parent that is approved but
has no branch to stack on satisfies the second and not the first.

**Fix.** The reconciler asks `JobStackResolver` (dry run without a Workflow, so a
fan-in stack never builds a prepared base during reconciliation).

**Spec.** `reconciler_spec.rb` "keeps a stack start block while the stack
resolver still says not ready" (red before).

**Review note.** The two Epic-turn cases match the two-query race fixed in F8;
check the rate after deploy.

---

## F18. The reconciler threw away in-place retries of transient git failures — fixed

**Property.** The reconciler never finishes a Step that the domain is
deliberately holding open for a scheduled in-place retry
(`Agreement.terminal_after_actionable`).

**Evidence (production, read-only).** On a merge train, 12 grader Runs failed
with `git_transport_transient` within about a minute (04:13–04:14 Eastern).
Each failure created a `failed_step` `AutoRetryAttempt` with a 5-minute backoff
and left its Step running. The 04:14 and 04:15 reconciler passes then reconciled
all 12 Steps to failed. A second train had 33 `git_transport_transient` grader
failures and 34 applied repairs over several hours. Some of those repairs
followed non-in-place failures, which were reconciled correctly. That train
failed, but it also had genuine grader failures, so the lost retries are not
proven to be the cause. Most of the ~50 applied repairs out of 324
`running_step_with_terminal_runs` executions in two days were this case.

**Counterexample.** `terminal_before_not_actionable`:
`classify_active_steps_with_terminal_runs` exempted only `worker_died` retries,
but `IN_PLACE_STEP_CLASSIFICATIONS` also contains `git_transport_transient`.

**Fix.** `AutoRetryAttempt.pending_in_place_step_retry_for?` covers every
in-place classification. The classifier, `step_needs_terminal_run_reconciliation?`
and the `reconcile_step_from_terminal_run` executor all use it. The executor
check covers a plan made before the retry was scheduled.

**Specs.**
- `reconciler_spec.rb` "leaves a running Step alone while an in-place
  git_transport_transient retry is pending" (red before).
- `repair_executor_spec.rb` "skips a Step waiting for a pending in-place retry".

**Review note.** The other 92 executions were skips ("Step is succeeded, not
active"). The classifier catches `RunJob#record_successful_step!` between
`run.succeed!` and `step.succeed!`. That window is harmless but noisy, and it's
the next target: make it unreachable.

---

## F19. A succeeded Run under a running Step was committed on every success — made unreachable

**Property.** No committed state has a running Step whose Runs have all
succeeded on the success path (`AtomicSuccess.atomic_hides`).

**Evidence.** 92 of the 324 `running_step_with_terminal_runs` executions in two
days were skips: "Step is succeeded, not active". The classifier saw the state
and the Step's commit landed before the executor ran.

**Counterexample.** `AtomicSuccess.split_exposes`:
`RunJob#record_successful_step!` (and the pre-admission skip path) committed
`run.succeed!`, then ran the Run's after-commit propagation, then committed
`step.succeed!`.

**Fix.** `RunJob#commit_run_and_step_success!` commits both in one transaction.
The trailing no-op `save!` calls were dropped. Inside a single transaction they
clear `saved_changes`, and then the `saved_change_to_state` conditions on the
commit callbacks never fire. The spec catches that, because the Step's chain
advance stopped while the Run and Step states still looked right.

**Specs.** `spec/jobs/run_job_success_atomicity_spec.rb`:
- Red before: the Run's propagation observed the Step as `running`.
- It also asserts the Step's propagation fires once.
- A second example covers clearing a stale `worker_died` outcome.

**Review note.** The Run's commit callbacks now run with the Step already
succeeded. Workflow admission wakeups therefore see the Step terminal, which is
the more accurate view.

---

## F20. The Job-state repair lifted Jobs the lifecycle left alone on purpose — fixed

**Property.** The reconciler lifts a Job to running only when starting its
latest Workflow would have lifted it (`Agreement.lift_after_agrees`). Every lift
the domain would make is kept (`lift_after_complete`).

**Evidence (production, read-only).** `unambiguous_job_state_drift` had 303
executions in about 2.5 days:
- 75 were queued → running, each on a different Job. Sampled Jobs were all
  `coworker_run` or `main_branch_repair` Workflows, which own their Job's
  lifecycle.
- 41 were implemented → running. For example, an implemented Job whose
  `initial` Workflow was still running after `pr_open`.
- 27 were skips where the drift had already gone.

**Counterexample.** `lift_before_disagrees`: `ReconcileJobStatesJob::Plan` lifted
every `[queued|implemented, running]` pair. Meanwhile:
- `JobLifecyclePropagation#start!` returns early for lifecycle-owning Workflows
  (infrastructure and `ManagesOwnJobLifecycle`).
- It also returns early for an implemented Job under a non-approval-blocking
  follow-up.
- `Steps::PrOpen` marks the Job implemented while the rest of the chain still
  runs.

The plan's own guard only exempted *child* lifecycle owners.

**Fix.**
- `JobLifecyclePropagation.lifts_job_on_start?` is the single rule. `start!`
  and both plan cases use it.
- `[implemented, running]` is no longer drift once the running Workflow has
  published its review PR (`review_publication_step_kinds`).

**Specs.** `reconcile_job_states_job_spec.rb` "lifting a Job to :running"
(5 examples):
- Red before: the lifecycle-owning case and the published-PR case.
- Kept: an approval-blocking follow-up and an ordinary start still lift.

**Review note.** One history is now left unrepaired. A succeeded Workflow that
had already published its PR is reopened, the reopen callback is bypassed, and
the Job stays implemented while the Workflow runs. With callbacks intact,
`reopen!` lifts it itself. From the Job and Workflow alone, "implemented after
pr_open" and "missed reopen" can't be told apart, so this is not
*unambiguous* drift.

The non-approval-blocking case already returned nil in a spec (`latest_workflow`
skips those follow-ups). The guard keeps the plan honest if that changes.

---

## F21. Terminal cleanup cancelled a retry's fresh work — fixed

**Property.** The reconciler cancels a Workflow's descendants only while the
Workflow is still terminal, decided under the lock that reopening holds
(`LockedCleanup.locked_safe`).

**Evidence (production, read-only).** At 00:36:34–37 Eastern on 2026-11-19, the
repair cancelled the grader tail of a failed `initial` Workflow. At 00:36:42 a
Retry-from-failed-step re-dispatched graders on the same Workflow. The repair
then reported "active descendants remain" for four of the retry's Runs, which
had already started and survived. The Workflow later succeeded after more churn.

**Counterexample.** `LockedCleanup.unlocked_damages`:
`CancelTerminalWorkflowActiveDescendants` checked `terminal?` and then called
`cancel_active_descendants!` without a lock. `RetryFailedStepEnqueuer` reopens
the Workflow inside `workflow.job.with_lock`.

**Fix.** The repair re-reads the Workflow under the same Job lock, checks it,
and cancels inside that lock. The lock order (Job first) matches the retry.

**Spec.** `repair_executor_spec.rb` "re-reads the Workflow under the Job lock
and leaves a just-reopened one alone" (red before). The spec simulates a retry
that committed while we waited for the lock.

**Review note.** Most of this issue's ~127 weekly repairs aren't races. They are
`Workflow#fail!` keeping its queued tail on purpose, followed by the reconciler
cancelling it. Those two intents contradict each other, which is NY4.

---

## F23. The reconciler continued review loops from review-panel fanouts — fixed

**Property.** The reconciler continues a review loop only from the Step the
dispatcher would continue it from (`Agreement.review_after_actionable`).

**Evidence (production, read-only).** 334 `succeeded_review_loop_needs_work_without_repair`
executions, all skipped. One Workflow logged seven in a row (01:20–01:27
Eastern on 2026-11-20). The target was the iteration-2 `adversarial_review`
*fanout*: it succeeded at 01:17:42, while its two panel members reviewed until
01:27 and the panel's collect decided at 01:27:42. During that time the
Workflow's latest verdict was still iteration 1's "needs_work".

**Counterexample.** `review_before_not_actionable`:
`StepDispatcher#handle_successful_review_loop_iteration` returns early for
`panel_fanout` and `panel_member` Steps, leaving the decision to
`review_panel_collect`. `classify_succeeded_review_steps_without_required_repair`
had no such exclusion, and its repair can only call the dispatcher.

**Fix.** `Step#review_panel_participant?` is a single predicate, used by both the
dispatcher and the classifier.

**Spec.** `reconciler_spec.rb` "leaves a review-panel fanout to its collect
Step". It goes red with the guard disabled.

---

## F24. Runs created during an inline drive waited for the reconciler — fixed

**Property.** Every queued Run either has a queue job or is the one Run the
current driver will run next, and never both
(`InlineHandoff.after_all_owned`, `after_no_double`).

**Evidence (production, read-only).** `queued_run_without_queue_claim` had 103
re-enqueues in a week, about 15 a day, spread evenly and not clustered around
deploys. Of the 20 I sampled:
- every one was the first Run of a new Step: 10 graders, 7 `landing_fix`, 2
  review-panel members, 1 `stack_force_push`;
- each sat 2–3 minutes without a queue job, then ran normally after the
  reconciler re-enqueued it.

**Counterexample.** `before_loses` and `before_loses_on_shutdown`:
- `Run#enqueue_run_job` skips the queue for any Run created while a RunJob
  drives the same Workflow.
- `RunJob#next_inline_run` picks at most one successor, found by walking
  `next_step` pointers from the Step it ran.
- So any other Run created in that window had no owner: parallel siblings,
  panel members, and repair Steps off the pointer chain.
- On SIGTERM the chosen successor was left "to be re-enqueued by the reaper".

**Fix.** Runs held back for inline driving are recorded in a thread-local list
(`Run::INLINE_HELD_RUN_IDS`). After every `next_inline_run`, and when the job
exits (normally, on SIGTERM, or by raising), `RunJob#release_inline_held_runs!`
re-enqueues every held Run except the one it will drive. A Run that is enqueued
in the meantime leaves the list, so nothing is enqueued twice. An enclosing
perform's list is captured before any early return and restored.

**Specs.** `spec/jobs/run_job_inline_successor_spec.rb` (all 3 red before):
- the off-chain Runs are enqueued;
- the driven successor is not enqueued;
- the successor is handed back on SIGTERM.

**Review note.** This changes graceful-deploy behaviour. A worker yielding on
SIGTERM now enqueues its successor immediately instead of waiting for the
reaper. That fits "lose as little work as possible on restart".

---

## F25. Every member of a rebased merge train failed verification — fixed

**Property.** A member whose commit reached the landed integration through a
clean rebase is recognised as landed (`RebasedMembers.after_accepts_rebased`).
A member none of whose patches reached it is still rejected (`after_sound`).

**Evidence (production, read-only).**
`succeeded_merge_train_failed_member_reconciliation` repaired 12 succeeded
trains in a week, with 1–7 members each. Three of the repairs line up to the
second with trains that finished through `merge_train_land_after_rebase`.
For one repaired member (a provider-account Job) I checked `main`:
- the member's PR head is not an ancestor of `main`;
- seven of its commits are on `main`, with new SHAs.

So the member landed, the inline check rejected it, and the reconciler closed it
about a minute later. In between, its landing was failed through
`LandingFailureHandler`.

**Counterexample.** `before_rejects_rebased`:
- `merge_train_rebase` rebases the whole integration branch onto the new base
  tip, and nothing re-records the members' LandedCommit rows.
- `member_landed?` asks whether the recorded (pre-rebase) SHA is an ancestor,
  and the answer is honestly no.
- The existing patch-equivalence fallback compares the member's *own branch*
  with the base. A `landing_fix` or a conflict resolution changes the content,
  so that fails too.

**Fix.** `rebased_into_integration?`: when this Workflow rebased its integration
branch (`merge_train_rebase_new_base_sha`), the member landed if a commit in
`new_base..integration_sha` has the same stable patch-id as the member's
recorded commit. Patch-ids are memoised per step. A conflict that an agent
resolved changes the patch-id and still falls through to the old checks.

**Specs.** `merge_train_steps_spec.rb` "after merge_train_rebase rewrote the
integration branch":
- recognises the rebased commit (red before);
- still fails a member whose patch is absent.

**Review note.** The reconciler's `RepairMergeTrainMemberReconciliation` closes
members as `pr_merged` from any `implementation` LandedCommit row in the train's
lifetime, without checking reachability. That was right for every case I
checked. But it would also close a member that a rebuilt train genuinely
dropped. With this fix it should rarely run. Worth hardening to the same
patch-id check if it keeps firing after deploy.

---

## F26. Missing workspaces on failed Workflows were flagged critical forever — fixed

**Property.** The reconciler reports a missing workspace only where
`recover_missing_workspace` can act (`Agreement.ws_after_actionable`).

**Evidence (production, read-only).** `workspace_missing` had 1,275 executions
all-time. 113 of the latest 150 were skips: "Workflow is no longer active".

**Counterexample.** `ws_before_not_actionable`: the classifier selected
`running? || retry_available?`, which includes a failed latest Workflow that
hasn't been cleaned up. The executor requires queued or running. A failed
Workflow with a lost workspace was therefore critical on every pass, and nothing
would ever act on it.

**Why dropping it is safe.** `RetryFailedStepEnqueuer` gates only on
`retry_available?`, not on the directory, so a retry still proceeds. The retried
Workflow is running, and its missing workspace is then classified and recovered
through the normal path.

**Fix.** The classifier selects running Workflows only. Their behaviour is
unchanged.

**Spec.** `reconciler_spec.rb` "does not flag a failed Workflow's missing
workspace the repair cannot act on" (red before).

---

## F27. Succeeded merge trains drew merge-train rebuild plans every pass — fixed

**Property.** `classify_retryable_failures` fires only where one of its repairs
can act. Its guard now also excludes succeeded Workflows
(`Agreement.retry_strict_actionable`), which tightens F4.

**Evidence (production, read-only).** Of the latest 150 `retryable_run_failure`
executions (13 hours), 115 were skipped `rebuild_merge_train`: "Workflow is not
in a failed state". There were 77 on one merge train and 38 on another, and both
had landed and succeeded. Each still carried failed grader Steps from an earlier
grade round, several of them the Steps F18's bug had failed.

**Counterexample.** `retry_after_not_actionable_strict`: F4 excluded queued and
running Workflows. But `rebuild_merge_train` requires failed, and
`retry_failed_step` requires `retry_available?` (failed), so a succeeded
Workflow was planned and refused forever.

**Fix.** Skip Runs whose Workflow succeeded.

**Spec.** `reconciler_spec.rb` "does not plan a retry for a failed Run on a
succeeded Workflow" (red before).

---

## F28 (NY4: A). A failed Workflow keeps its queued tail — implemented

**Decision.** `Workflow#fail!` keeps the downstream queued Steps for
Retry-from-failed-step. The reconciler had been cancelling them about a minute
later, roughly 127 repairs a week. A cancelled tail Step that already had a Run
could not be revived by the retry.

**Change.**
- `Workflow#stale_terminal_steps`: on a failed Workflow, only running Steps,
  plus an active publication Step that already failed. Cleanup still fails that
  Step, so it stays the Step the retry resumes from.
- The classifier and `cancel_terminal_workflow_active_descendants` both use it.
- `Workflow#cancel_stale_terminal_descendants!` cancels live Runs through
  `Run#cancel_without_step_cascade!`. That is a column update, so the cancel
  doesn't cascade to the Step, and it still records the reconciler transition
  that `controlling_run_for_failed_step` relies on to see past the cancelled
  replacement.

**Proof.** `Agreement.tail_after_agrees` and `tail_after_complete`.

**Specs.** `reconciler_spec.rb` "a failed Workflow's queued tail" (2 examples):
the tail is left for the retry, and it loses a live Run but keeps its Step.
Two existing specs were updated to the decided behaviour; the cancellation-details
spec now uses a cancelled Workflow.

---

## F29 (NY5: A). Validation prefetches may outlive a landed parent — implemented

**Decision.** A `LandingValidationChild` WorkUnit whose parent *succeeded* keeps
running. It is the prefetch the next landing reuses. Children of a failed or
cancelled parent are still cancelled.

**Change.** `classify_active_child_work_units_with_terminal_parents` skips
`validation_prefetch_of_landed_parent?`.

**Proof.** `Agreement.prefetch_of_landed_parent_kept` and
`other_children_of_terminal_parents_stale`.

**Specs.** `reconciler_spec.rb` "leaves a landed parent's validation prefetch
running". The existing cancellation spec now uses a failed parent.

---

## F30 (NY2: both wait). Epic-wide work waits for running member work — implemented

**Decision.** Neither side preempts the other. Members already waited while
Epic-wide work (merge trains, stack rebases) was queued or running. An
Epic-wide Workflow could start while a member's own Workflow ran, and the
reconciler then cancelled the member's running work.

**The trap, and why the rule reads "running".** If the Epic-wide Workflow also
waited for *queued* members, the two would deadlock: queued members wait for
the queued Epic-wide Workflow, and it waits for them
(`EpicWide.naive_deadlocks`). The decided rule never deadlocks, keeps the Epic
exclusive, and can't starve the Epic-wide Workflow, since a queued one blocks
new member starts:
- `decided_exclusive` and `decided_deadlock_free`, checked over every
  interleaving of up to 6 operations;
- `queued_epic_wide_blocks_new_members`;
- `queued_epic_wide_starts_when_members_idle`.

**Change.**
- `EpicWorkflowLock#running_member_workflow` returns the oldest running,
  non-Epic-wide Workflow on a Job in the Epic.
- `StepDispatcher.start_workflow` start-blocks an Epic-wide Workflow with
  `epic_member_work_running` (and an admission wakeup) while one exists.
- The reconciler's start-block judgement knows the new reason.

**Specs.** `step_dispatcher_spec.rb`:
- "waits until no member workflow is running" (red before);
- "is not held up by member work that is only queued" (the deadlock case);
- "holds Epic-wide workflows for running member work, not for the sibling
  gate" (replaces the merge_train/stack_rebase half of the sibling-gate bypass
  spec, which assumed the old start rule).

**Review note.** `classify_epic_workflow_conflicts` still cancels on a
conflict. With both start rules in place, a conflict now needs the two checks
to race. Taking a shared Epic lock around the check and the start would rule
that out too; not done here.

---

## F31 (NY3: A). Run execution is fenced by an attempt counter — implemented

**Decision.** Add a fencing token at the existing checkpoints.

**Gap.** Recovery requeues a Run whose worker looks dead. If that worker was
only stalled, it resumed and carried on: commit, push, call GitHub.
`ensure_run_still_active!` refused only *terminal* records, and a requeued Run
is queued, a reclaimed one running (`ExecutionFence.before_stale_passes`,
`before_requeued_passes`).

**Change.**
- Migration `AddExecutionAttemptToRuns` (integer, default 0, idempotent).
- `RunJob#acquire_run_execution!` increments it on every claim and keeps the
  claimed value on the in-memory Run (`Run#claimed_execution_attempt`).
- `Steps::Base#ensure_run_still_active!` (already called before agent work and
  every merge, F12) also raises `RunEndedExternally` when this process claimed
  the Run and the row is no longer running, or its attempt moved on. RunJob
  logs the stop and leaves all state to the current owner.
- Handlers run outside RunJob (most specs) have no claim, so they keep the old
  terminal-only check.

**Proof.** `ExecutionFence.after_stale_stopped`, `after_requeued_stopped`,
`after_owner_passes`, and `at_most_one_passes` (two claimants can't both pass).

**Spec.** `spec/services/steps/run_execution_fencing_spec.rb` (5 examples). The
two stalled-executor cases go red with the check disabled.

**Review note.** This fences at the checkpoints that exist: before agent work
and before merges. A side effect between two checkpoints, such as a push in the
middle of a Step, isn't fenced, which is option B in the original question.

---

## F32. The urgent-Job start block had no recheck — fixed

**Property.** Every start block either clears on an event that wakes the
blocked Workflow, or has its own scheduled recheck.

**Gap.** `urgent_job_active` was recorded with no `WorkflowPhaseAdmissionJob`.
The only wake was `UrgentJobClosedJob`, which runs when an urgent Job closes.
But the gate also releases when an urgent Job stops progressing
(`UrgentWorkGate.progressing` lets a parked urgent Job stop holding it), and
nothing wakes the blocked Workflow then. It waited for the reconciler to judge
the block stale. That is the gap the main-health gate had before its recheck
was added; its comment says so.

**Fix.** Schedule the same recheck the neighbouring gates do.

**Spec.** `step_dispatcher_spec.rb` "schedules its own recheck, like the
neighbouring gates". It goes red with the recheck removed.

---

## F33. A polled GitHub review approved Jobs under approval-blocking work — fixed

**Property.** No approval path changes a Job's state while it has
approval-blocking runtime work (`ApprovalPaths.NoApprovalUnderBlockingWork`).

**Gap.** The operator endpoint, the `approve_job` MCP tool and the
approve-job pending action all refuse while `approval_blocking_runtime_work?`
holds. `Job#record_github_review_approval!`, which the PR poll, the
external-PR poll and the fork-review approver call, did two things first:

1. `mark_implemented! if may_mark_implemented?`. A `running` Job became
   `implemented` under its live Workflow, even when the approval was then
   declined because a feedback Workflow was active
   (`github_before_drifts_under_feedback`).
2. It checked only `active_feedback_workflow?`, so a GitHub review approved a
   Job under any non-feedback approval-blocking Workflow, such as `ci_failure`
   or `retry` (`github_before_violates`), approving a HEAD that Workflow was
   about to move.

**How it was found.** Tracing the `running → implemented` Job-state repairs.
Four of the five were the echo of F20: the reconciler wrongly moved a Job
from `implemented` to `running` about a minute before its Workflow succeeded.
The success propagation (`JobLifecyclePropagation.succeed!`) then decided on
the Workflow's cached Job, loaded before that repair, which still said
`implemented`, so it returned early and the next pass had to fix the Job.
Looking for other writers that could change a Job under a running Workflow
led to the GitHub path.

**Fix.** Refuse while approval-blocking work runs, before writing anything.
Each poll re-reads the PR's reviews, so the approval is recorded on the first
poll after the work ends (`github_after_eventually_approves`). With no
blocking work, behaviour is unchanged (`github_after_agrees_when_idle`).

**Spec.** `job_spec.rb` "neither approves nor leaves running while a
non-feedback approval-blocking workflow runs" and "does not move a running
Job to implemented when a feedback workflow declines the approval". Both go
red without the fix. "still approves under non-approval-blocking work" pins
the `rebase` exemption. The `fork_review_approver_spec.rb` self-policy
fixture approved while its initial Workflow was still queued; it now finishes
that Workflow first.

**Remaining.** `ForkReviewApprover` runs once: it returns as soon as the
upstream PR exists. A fork approval refused under blocking work is therefore
not re-recorded. The approval is withheld, not wrongly given, and the
operator can still approve, but it is a liveness gap. This was already true
under a feedback Workflow before the fix. Also: `JobLifecyclePropagation`
decides on the Workflow's cached Job instead of reloading it under the Job
lock. With F20 and F33 no known writer changes a Job under a running
approval-blocking Workflow, so this is not exploitable today, but it is
check-then-act on a stale snapshot.

---

## F34. The reconciler cancelled the Epic waits F30 introduced — fixed

**Property.** The reconciler leaves every state the decided Epic start rule
(NY2) reaches alone, and still repairs every violation of exclusivity
(`EpicWide.recon_after_agrees`, `recon_after_restores_exclusive`).

**Gap.** `EpicWorkflowLock::ConflictDetector` kept the oldest active
Epic-wide unit and reported *every* other active member unit as a conflict.
It did this whether the member was queued or running, and even when the
keeper itself was only queued. Under NY2 both are deliberate waits:

- A member queued behind an Epic-wide Workflow is start-blocked
  (`epic_wide_workflow_active`). The reconciler cancelled it
  (`recon_before_cancels_queued_member`).
- An Epic-wide Workflow queued behind a running member is start-blocked
  (`epic_member_work_running`). The reconciler made it the keeper and
  cancelled the *running* member (`recon_before_preempts_running_member`).
  That is exactly the preemption NY2 rejected, so F30's half of the rule was
  undone by the reconciler.

**Evidence (production, read-only).** Of 13 applied `epic_workflow_conflict`
cancellations, 11 hit members that had never started. One pass cancelled six
queued `initial` Workflows of one Epic behind a `stack_rebase`. For JOB-9430
the queued-job repair relaunched the member, and the next pass cancelled it
again, once a minute until the `stack_rebase` finished. The Job meanwhile
went `failed` and was dragged back to `queued`, which was one of the two
untraced `failed → queued` Job-state repairs.

**Fix.** A second Epic-wide Workflow is still always a conflict (the
dispatcher cancels one that cannot start). A member conflicts only while
both it and the keeper are running. The executor
(`CancelEpicWorkflowConflict`) re-checks the same rule under the Workflow
lock instead of only "both active".

**Spec.** `epic_workflow_lock_spec.rb` "conflicts agree with the Epic start
waits": a queued member and a running member under a queued keeper are left
alone (both red before), while running-vs-running and a second Epic-wide
Workflow are still reported. `repair_executor_spec.rb`
"cancel_epic_workflow_conflict": a waiting member is skipped (red with the
guard removed), and a running one is cancelled.

**Correction (F34).** The coverage note for `epic-wide-workflow-conflict` said
that after F30 the reconciler's cancellation remained only as a backstop for
a race. That was wrong, and it is corrected there.

---

## F35. The inline landing door could jump the queue — fixed

**Property.** A unit lands only if every unit ahead of it in the same landing
slot is blocked. Blocked units do not hold the queue
(`QueueOrder.InOrder`).

**Gap.** `LandingQueueProcessor#call` walks the queue in priority, approval
time and dependency order and lands the first eligible unit. `try_land!(job)`
is the inline door: approval, auto-approval and mergeability refreshes call
it so a ready Job lands without waiting for the next tick. It checked only
that Job's own blockage. When a Job was approved while an older or
higher-priority Job of the same slot had already become eligible, and the
next tick hadn't run yet, the new Job took the slot first
(`tryLand_before_jumps`). This breaks the documented "ordered by priority and
FIFO approval time".

**Fix.** Before landing its own Job, `try_land!` checks for an eligible unit
of the same slot ahead of it. If there is one, it runs the ordered pass
instead. Both doors now pick the same unit (`tryLand_after_agrees`), and the
inline door still lands its own Job when it is first in line
(`tryLand_after_lands_front`).

**Spec.** `landing_queue_processor_spec.rb` ".try_land!": "lands the front of
the queue rather than jumping an earlier eligible Job" and "honours priority
over approval time for the inline door too" (both red before), plus "still
lands its own Job when an earlier Job is blocked".

---

## F36. "Nothing left" while the last Step waits for an in-place retry — fixed

**Property.** Every Workflow the "nothing left" classifier flags is one its
repair can act on (`Agreement.tail_held_after_actionable`).

**Gap.** This is one of the three definitions of an active Step.
`running_workflow_without_active_descendants` and its repair
`FinishWorkflowFromTerminalDescendants` judge a Workflow by the *projected*
Step states, which follow the latest Run. A Step held for an in-place retry
(F18: Step `running`, only Run `failed`, retry pending for 5 to 60 minutes)
projects as terminal. When it is the Workflow's last Step, the classifier
flags the Workflow. The repair then infers the outcome from the *persisted*
last Step, which is `running`, so it gets nil. It reports "No terminal outcome
could be inferred; operator review is required" on every pass until the
retry runs (`tail_held_before_not_actionable`). If the held Step has queued
successors, they keep the Workflow active, which is why the F18 spec never
saw this.

**Production.** Not yet observed. Before F18 is deployed, the active-step
classifier reaches these Steps first and throws the retry away. Once F18 is
deployed, this branch would have been the next to trip on them.

**Fix.** One predicate, `AutoRetryAttempt.pending_in_place_step_retry_in?(workflow)`,
used by both the classifier and the executor guard.

**Spec.** `reconciler_spec.rb` "does not report a Workflow with nothing left
while its last Step waits for an in-place retry" and `repair_executor_spec.rb`
"finish_workflow_from_terminal_descendants". Both go red without their half
of the fix; the executor spec then reports the false operator-review alarm.

**Remaining (two-definitions-of-active-step).** Persisted (`steps.active`)
and projected (`StateProjection`) activity still differ for any Step whose
Runs are all terminal while the Step stays active. Known producers: the F19
success window (closed), the in-place retry hold (now recognised), and the
run-only cancellations (`cancel_without_step_cascade!` on failed Workflows,
which are terminal and so are not classified, and
`ImmutableReviewHeadBarrier.cancel_run_without_cascade!`, not yet traced).

---

## F37. The admin work-units listing failed on deep pages — fixed (found in passing)

Not an engine finding: it turned up while scanning production for
Workflows with two WorkUnits (read-only). `GET
/api/v1/app/admin/work_units?page=30` returned 500 with `Mysql2::Error: Out
of sort memory`. At a deep offset MySQL chose a filesort over the
`(requested_at, id)` index and sorted whole `work_intents` rows, JSON columns
included, so every page past roughly the thirtieth was unreachable. The
payload now pages over the id and sort columns only and then loads that
page's records by id, keeping the order. It selects instead of plucking,
because a joined filter adds `DISTINCT` and MySQL rejects ORDER BY columns
missing from the select. Spec: `work_units_spec.rb` "pages over narrow rows
and keeps the requested order" (red before: the paging query selected
`"work_intents".*`).

---

## F38. Skipping an in-place retry ended the unit under its running Workflow — fixed

**Property.** While a Workflow is active, its WorkUnit is active and holds
its locks once the Workflow runs (`UnitReentry.LiveWorkflowOwned`).

**Gap.** `AutoRetryBackoff.record!` blocks the Workflow's unit while an
auto-retry sleeps. For an in-place step retry, that Workflow is still
running. When the attempt was skipped (failure no longer retryable, source
Step recovered or superseded, branch rewritten, retry execution error),
`clear!` defaulted to `mark_terminal!("failed")`. The unit ended and released
its locks while the Workflow, and any parallel Steps still in it, kept
running (`clear_before_breaks`). The next `TerminalWorkflowSync`, which treats
a terminal unit as authoritative, then failed the Workflow. That happened
even when the skip meant the Workflow had moved on. A probe confirmed the
sequence: blocked → skip → unit `failed` with 0 locks, Workflow `running` →
sync → Workflow `failed`.

**The disagreement underneath.** For "active Workflow, terminal unit", the
code has two opposite rules. `TerminalWorkflowSync` makes the Workflow follow
the unit. `DeferredPhaseResume#reactivate_terminal_unit_for_active_workflow!`
makes the unit follow the Workflow. This was the known producer of the state.

**Fix.** `clear!` ends the unit only once its Workflow is itself terminal.
Otherwise it hands the unit back (`resume_for_workflow!`, which re-acquires
the locks). If the retry was abandoned, the held Step is failed through the
Workflow's own path, since F18/F36 no longer see a pending attempt
(`clear_after_keeps`).

**Spec.** `auto_retry_backoff_spec.rb` "hands the unit back to a still-running
Workflow when an in-place retry is skipped" (red before). The existing skip
example now uses a failed Workflow, which is the case it describes.

**Remaining.** Fixed as F39.

---

## F39. A lock-blocked phase resume had no recheck — fixed

Same property as F32: every wait wakes on an event or has its own recheck.
`DeferredPhaseResume#reactivate_terminal_unit_for_active_workflow!` lets a
`LockConflict` from `mark_running!` (another unit holds a lock this Workflow
needs) escape. `WorkflowPhaseAdmissionJob` retries only database lock errors,
so the job failed and nothing rechecked the deferred phase. The
`JobManualPause` resume and the reconciler's resume repairs raised the same
way. Now the conflict is reported as `blocked` / `active_work_lock` and
schedules a phase-admission recheck. Spec: `deferred_phase_resume_spec.rb`
"reports a lock-blocked reactivation and schedules its own recheck" (red
before: the exception escaped).

---

## F40. The reconciler resumed Steps whose gate recheck was already due — fixed

**Evidence (production, read-only).** In the last 1,000 repair executions,
covering about 9 hours, 437 were skipped `resume_queued_step` repairs with
the message "queued Step remained deferred: blocked: ci_repair_safety". This
is the F16 pattern again. F16 exempted only pauses (`manual_pause`,
`provider_availability`; those 380 skips are pre-F16 code still running in
production). Any gate that blocks with `retry_at` has already scheduled its
own phase-admission recheck for `blocked_until`. The reconciler resumed the
Step every minute anyway: the gate re-ran, refused, and pushed `blocked_until`
forward (`Agreement.gated_before_refused`).

**Fix.** `WorkUnit#deliberate_wait?`: blocked on a pause, or blocked with
`blocked_until` still in the future. The queued-Step classifier skips such
units. Once `blocked_until` has passed (a lost or overdue recheck), the
reconciler acts again as the safety net (`gated_after_skips_due`).

**Spec.** `reconciler_spec.rb` "does not flag a queued Step whose gate
recheck is still due, and does once it is overdue" (red before).

**Also in this sample.** (1) Five `NameError: undefined method
'proactive_pause_threshold'` failures in a 6-minute window on two Workflows.
The column came with a migration the day before, so these are a deploy
ordering artefact (code running against a schema cache from before the
migration), not an engine bug. (2) A rare flake in `reconciler_chaos_spec.rb`
"reconciles one random degradation on a fully materialized random workflow
topology": 1 failure in about 27 runs, seed not captured. Its workflows are
built without the launcher and have no WorkUnit, so F40 cannot affect it.

---

## F41. Mixed unit outcomes could settle an intent from a stale unit — fixed

**Property.** An intent is settled by the outcome of its latest finished
unit, the one `WorkIntents::TerminalUnitSync` acts on
(`Agreement.mixed_after_agrees`).

**Gap.** The reconciler's backstops for a missed sync
(`succeeded_work_unit_unsatisfied_intent`, `failed_work_unit_unfailed_intent`,
`superseded_work_unit_uncancelled_intent`) each looked at every terminal unit
of the intent. Take an intent whose older unit succeeded and whose newer
retry failed. If the sync was missed, it was flagged both ways, and whichever
repair ran first won, possibly the stale success
(`mixed_before_flags_both`).

**Fix.** `WorkIntent#settled_by?(unit)` (the latest finished unit) gates all
three classifiers and their executors.

**Spec.** `reconciler_spec.rb` "settles an intent with mixed unit outcomes
from its latest unit only" (red before) and `repair_executor_spec.rb`
"satisfy_work_intent_from_succeeded_work_unit".

---

## F42. Intents of finished work stayed requested — fixed

**Evidence (production, read-only).** 92 WorkIntents were `requested`. 87 of
them had no active unit, only cancelled units, cancelled with these reasons:
`job_closed` (mostly `stack_rebase`, `job_bundle`, `merge_train`),
`terminal_parent_work_unit` (validation children), `retired_for_implementation_retry`,
and Epic-conflict victims.

**Gap.** `WorkIntents::TerminalUnitSync` cancels an intent only when its unit
was cancelled for a reason in `SUPERSEDING_CANCEL_REASONS`. Any other
cancellation leaves the intent requested so that it can be relaunched. But
the generic relaunch (`requested_work_intent_without_active_unit`) runs only
when the reconciler is called with a `work_intent_id`, which no production
path does. For work that is over, a requested intent is simply stranded. The
close-time sweep (`Job#cancel_stale_work_intents_after_close`) skips intents
whose unit is still active and only looks at Job-scoped intents, so Epic and
train intents of a closed Job were never cancelled (closed-job-open-intent).

**Fix.** `job_closed`, `terminal_parent_work_unit` and
`retired_for_implementation_retry` end the intent with the unit. The
reconciler's superseded-unit backstop shares the list, so after deploy it
also cancels the 87 already stranded. Epic-conflict victims stay requested:
they are meant to be relaunched, and F34 stops creating them.

**Spec.** `terminal_unit_sync_spec.rb`: one example per reason (all red
before), and "keeps an Epic-conflict victim's intent requested for its
relaunch".

**Also found.** My earlier production scan for Workflows with two units
(one-unit-per-workflow) read the wrong key from the admin payload (`units`,
not `work_units`), so it checked nothing. The corrected rerun covered the
most recent 2,900 intents (2,935 units) and found no Workflow with two units.

---

## F43. The stale-train repair could fail a train that had an owner — fixed

**Gap.** `classify_stale_active_merge_trains_without_runtime` counts as the
train's owner a queued, running or *blocked* train Workflow, an active unit,
or a pending preserved-train relaunch. Its repair `FailStaleActiveMergeTrain`
re-checked only queued and running Workflows and active units. An owner of
the other two kinds that appeared between planning and execution (a
`MergeTrainFailureHandler` relaunch being scheduled, a Workflow blocking on
admission) did not stop it. It failed the train, discarding the preserved
assembly and the real failure reason (`Agreement.train_before_fails_owned`).

**Fix.** `WorkEngine::MergeTrainOwnership#owned?`, shared by the classifier
and the repair.

**Spec.** `reconciler_spec.rb` "a stale active merge train … is not failed by
an already-planned repair once a relaunch is pending". Red on the old
executor: it applied the repair.

---

## F44. Retries from a rewritten branch were planned forever — fixed

**Property.** Auto-retry terminates. The budget is cumulative per (Job,
provider, failure classification), so new Workflows don't reset it. Every
skip reason the budget exempts must describe something transient.

**Gap.** `AutoRetryJob` skips an attempt whose source Run's workspace the PR
branch has since moved past (`job branch was rewritten…`). That reason is
budget-exempt, and the skip requests a reconciliation. The retry planner
(`classify_retryable_failures`) never checked the same condition. The per-Run
dedup ignores skipped attempts, so every pass scheduled another attempt from
the same Run, and the skip immediately triggered the next pass. While the
branch stays moved, nothing ends it (`Agreement.rewritten_before_loops`). A
probe showed attempts #1, #2, #3 in three passes, all skipped for the same
reason.

**Fix (as first committed).** `AutoRetryAttempt.branch_rewritten_since?(job, run)`,
shared by the pre-start skip and the retry classifier (`rewritten_after_bounded`).
That guard was too broad and is superseded by F45: it also suppressed fresh
`retry_workflow` retries, which a moved branch does not make stale.

**Spec.** `reconciler_spec.rb` "does not keep scheduling retries from a Run
whose branch was rewritten" (red before: 3 attempts in 3 passes).

---

## F45. The branch-divergence recovery could never run — fixed (refines F44)

**Gap.** `AutoRetryJob`'s rewritten-branch skip applied to every retry kind.
Its rationale is that the source Run's *workspace* is stale, and only
same-attempt retries (`failed_step`, `resume_failed_step`) reuse that
workspace. `classify_branch_divergence` plans a `retry_workflow` from the
current PR branch precisely because the branch moved. The skip caught it
every time, and since the skip is budget-exempt and requests a
reconciliation, the recovery was replanned every pass and never performed.
A probe showed three `retry_workflow` attempts in three passes, all skipped.
The resumable-session planner had the F44 loop as well (3 resumes in 3
passes).

**Fix.** The skip applies only to same-attempt kinds
(`AutoRetryAttempt#same_attempt_retry?`). For a rewritten Run, the retry
planner (`RepairPlanner`) skips resume and in-place retry and plans a fresh
`retry_workflow`. The resumable-session classifier, which only offers resume,
excludes rewritten Runs. F44's classifier-level guard is removed. The model is
`Agreement.planned_retry_never_skipped`; the old behaviour is
`divergence_recovery_skipped_before`.

**Spec.** `reconciler_spec.rb` "performs the branch-divergence recovery retry
instead of skipping it as rewritten" and "does not keep planning resumes from
a Run whose branch was rewritten" (both red before). F44's spec still holds:
the rewritten Run now gets a single fresh retry.

**Production (read-only).** The only `branch_diverged_pr_open` repairs in the
retained history are three consecutive `retry_workflow` attempts for one Job
within two minutes (Nov 18, 12:41–12:43). That is consistent with the
skip-and-replan loop, but it stopped after three, and the attempts' skip
reasons are past the activity retention, so it is not proof.

---

## F46. Coworker workflow tool calls depended on daemon wrap order — fixed (Lead L3)

**Found from** an order-dependent failure in `persistent_mcp_daemon_spec.rb`
"dispatches owner-scoped coworker chat discovery…". It passed alone and
failed after the Coworkers plugin specs. The `list_chats` result was
"Unauthorized: invocation context Malformed: invocation token surface :run is
not chat".

**Gap.** The persistent MCP daemon serves the chat and workflow routes in one
process. A tool served on both routes (the coworkers' `list_chats`,
`search_chats`) has both `ChatToolDispatch` and `WorkflowToolDispatch`
prepended to its class, each once, on first use, so whichever was wrapped last
is outermost. `WorkflowToolDispatch` passes through calls that did not come
in on a workflow route. `ChatToolDispatch` passed through only calls without
a daemon identity, and a workflow-route call carries one. So with the chat
wrapper outermost it resolved a chat context from the run token and refused
the call. In production this is latent: the health check enumerates chat
tools at boot, so the chat wrapper usually goes on first. But if a workflow
request ever arrived first, coworkers' chat-reading tools would be refused
for the life of that daemon process (`DispatchOrder.before_depends_on_order`).

**Fix.** `ChatToolDispatch` also passes through workflow-route calls
(`workflow_role` present). Each wrapper handles only its own route, so the
order no longer matters (`after_order_independent`, `after_serves_both`).

**Spec.** `spec/services/persistent_mcp_daemon/dispatch_order_spec.rb` wraps a
probe tool in the bad order. It is red before the fix. The original failure
order (Coworkers specs, then the daemon spec) passes: 982 examples.

---

## F47. Scheduled runs skipped permission rules in persistent MCP mode — fixed (Lead L3)

**Gap.** The capability authorization layer
(`Mcp::Tools::AuthorizationSupport::ToolDispatch`) is installed on a tool
class lazily, by `Mcp::Sidecar.authorize_tool`. The stdio sidecar installs it
on every tool it serves, and so does `ChatToolDispatch.wrap`.
`WorkflowToolDispatch.wrap`, used by the persistent daemon's workflow route,
did not. The persistent sidecar is on by default
(`Feature.persistent_mcp_sidecar_enabled?`). So a permission-gated tool served
only on the workflow route reached its body without
`Permissions::ScheduledAuthorization` running, and a scheduled (cron) run
skipped the owner's deny and approval rules for it. That held unless some
other path in the same daemon process had already wrapped that class. A
probe in a fresh process found the two gated workflow-only tools,
`patch_workflow` and `read_artifact`, unwrapped
(`DispatchOrder.workflow_only_tool_unauthorized_before`).

**Fix.** `WorkflowToolDispatch.wrap` installs the authorization layer first,
as the chat wrapper does, so the layer sits inside the route wrapper and sees
the resolved run context (`served_tool_authorized_after`).

**Spec.** `persistent_mcp_daemon_spec.rb` "runs the capability authorization
layer for a gated workflow-only tool". Red before: `ScheduledAuthorization`
was consulted 0 times.

**Lead L3 after F46 and F47.** Both daemon routes now install authorization
on first wrap, and the wrappers no longer depend on order. Authorization is
still installed lazily by prepend, so a class that some path serves without
going through one of the three wrappers is still unguarded. Making it
structural (install on registration in `McpToolRegistry`) would close the
lead.

---

## NY9 (decided A). Authorization installed at registration

`McpToolRegistry#entry` now calls `Mcp::Sidecar.authorize_tool` for every
registered tool. That is idempotent, and it runs before any route wrapper, so
the layer stays innermost. Whether a tool is gated therefore no longer
depends on which path served it first, which closes Lead L3
(`DispatchOrder.registered_tool_always_authorized`). Read in a fresh process
without the change, about 277 registered tools lacked the layer.
`spec/architecture/mcp_tool_authorization_spec.rb` now fails if any
registered tool lacks it.

Making the layer universal surfaced the other half of L3. Two specs passed
only because their tools happened to be unwrapped:
`ci_read_tools_spec.rb` "refuses outside a workflow run" and
`read_live_state_tool_spec.rb` "returns a tool error for an invalid run
context". Called with an unusable context, the layer raised while building
it, before the tool ran. The pre-call checks
(`AuthorizationSupport.authorization_gate`) now fail closed with the tool
error response the tool itself would give. An authorization error still maps
to `not_authorized`, and errors from the tool body propagate as before.

Also fixed on the way: `work_unit_workflow_ownership_spec.rb` defined global
constants in its describe block (`ALLOWED`), which clobbered
`repository_content_reads_spec.rb`'s whenever both ran in one process.

---

## F48. A dependency on a Job finished after a withdrawn approval waited forever — fixed

**Found by** the DOC-44 kernel dependency model (`Kernel/Dependencies.lean`).

**Property.** Once the upstream Job is closed, every dependency on it is
decided: either satisfied, or terminally unsuccessful (`closed_decided`). The
two never hold together (`never_both`).

**Gap.** `JobDependency#execution_dependency_satisfied?` returned false
whenever the upstream approval was withdrawn (every mode except `closed`),
even after the dependency had succeeded. Only approving clears
`approval_withdrawn_at`. A Job whose approval was withdrawn and that was then
merged on GitHub (closed `pr_merged` or `external_pr_merged`), emergency-landed
or closed with no changes is succeeded *and* still marked withdrawn. Its
dependents were not satisfied, and not terminally unsuccessful either (it
succeeded), so they neither started nor failed closed
(`closed_undecided_before`). The exhaustive check over all modes and upstream
states finds every such case.

**Fix.** A withdrawn approval only blocks a dependency that has not succeeded
yet. The fix only ever turns waiting into satisfied (`after_extends_before`),
and only for a dependency that has already succeeded
(`after_differs_only_when_succeeded`). That includes a deployment stage
reached while the upstream Job is still open.

**Spec.** `job_dependency_spec.rb` "an upstream Job that succeeded after its
approval was withdrawn" (success and landed modes, both red before), plus
"still blocks a ready-but-unfinished upstream whose approval was withdrawn".

---

## F49. Auto-merge merged when it could not read the base — fixed

**Found by** DOC-44 Phase 3, landing evidence (`LandingBase.lean`).

**Property.** A landing merges only onto the base its landing graders
validated: with a recorded validated base, a merge happens only if the live
base was read and equals it (`after_merge_confirms_base`).

**Gap.** `Steps::AutoMergeControl#defer_if_base_moved_since_validation!` runs
right before `AutoMerge` and `ExternalPrMerge` call GitHub's merge. It read the
live base head and deferred if it differed from `job.mergeability_base_sha`.
An error from that read, or a blank SHA, returned "unchanged", and the merge
went ahead. GitHub's rebase merge then lands the head onto whatever the base is
now, which no grader ran on (`fail_open_on_error`, `fail_open_on_blank`). The
merge-train path already fails closed on the same question
(`ensure_base_unchanged!`).

**Fix.** An unreadable live base defers landing for a re-check (approval kept,
artifact `landing_base_moved` with reason `base_unverified_before_merge`). The
fix only turns merges into deferrals, and only when the base could not be read
(`after_never_adds_merges`, `after_differs_only_when_unread`). NY10 (decided
A): a blank *recorded* base defers too (`validated_base_not_recorded`), so every
merge had its validated base read and unchanged (`afterNY10_merge_confirmed`).

**Spec.** `auto_merge_spec.rb` "defers instead of merging when GitHub errors
reading the base before the merge" and "...when GitHub returns no SHA..."
(both merged before).

---

## F50. A landing repair kept a repo-wide grader's pass after its dependency changed — fixed

**Found by** DOC-44 Phase 3, following M3's trust boundary into the reuse
decision (`RepairReuse.lean`).

**Property.** After a code-changing landing repair, an earlier pass is kept
only if no file the grader reads changed anywhere in the iteration
(`keepAfter_nothing_read_changed`). This holds whenever the grader reads a
scoped set of files at all. A kept pass becomes a `carried_forward` manifest
result, which the landing gate accepts on fingerprints alone (M3).

**Gap.** `Steps::GraderFanout#partition_evidence_driven_repair_graders` checks
the repair Run's own diff against the target's scope (or its dependencies'
scopes, for a repo-wide target). It compared the input fingerprint only for a
target with its own scope. But `format` and `generate` run after the repair and
commit too. A repo-wide grader depending on a scoped target (say generated
code under `lib/**`) kept its earlier pass after `generate` rewrote that code,
so the landing could merge code the grader never ran on
(`kept_after_generated_change`).

**Fix.** The input fingerprint (the hash of every file in the target's and its
dependencies' scopes) is also compared when only a dependency has a scope
(`scoped_closure?`). The fix only reruns more (`keepAfter_implies_keepBefore`),
and only for that shape of target (`keep_differs_only_for_scoped_dependencies`).
A repo-wide target with no scoped dependency is still kept after a narrow
repair, as documented (`metadata.always_rerun` opts out).

**Spec.** `grader_fanout_spec.rb` "reruns a repo-wide grader when its
dependency's sources changed outside the repair's own diff" (kept before).

---

## F51. A landed main repair declared later, ungraded commits healthy — fixed

**Found by** DOC-44 Phase 3, main-branch repair (`RepairLift.lean`).

**Property.** When a main-branch repair lands, only the commit its landing
validated (`job.landed_sha`) is declared healthy, and the strict-policy pause
lifts only on that evidence (`after_declares_only_landed`).

**Gap.** `MainHealthChangedService#repair_landed!` (called when the repair Job
closes as merged) recorded CI and grader health as healthy for the *live*
default-branch head, then called `recovered!`, which lifts the landing pause and
releases held work. If anything reached main after the repair, through an
isolation-policy landing or a manual push, that commit was declared healthy
without being graded, and the pause lifted on stale evidence
(`later_commit_declared_healthy`).

**Fix.** When main has already moved past the repair's landed commit,
`repair_landed!` enqueues a health poll for the live head instead. The pause
stays until that grade comes back. The fix only withholds declarations
(`after_declare_was_before`). A repair with no recorded landed SHA keeps the
old behaviour.

**Spec.** `main_health_changed_service_spec.rb` "does not declare a later,
ungraded main head healthy or lift the pause" (lifted it before).

---

## F52. Inline-chained Runs were declared dead while their worker was alive — fixed

**Found by** deriving the invariant behind a recent main commit ("Do not
declare a worker dead over one orphaned helper process") and checking where
it fails (`WorkerEvidence.lean`).

**Property.** A Run that a live queue claim is executing is recognised as live
(`after_complete`), so neither an orphaned helper process nor a missing queue
job of its own gets it failed as `worker_died`. A running sibling's claim is
still never borrowed (`after_ignores_running_siblings`, the existing rule
pinned by "does not treat a live sibling Run queue execution as evidence for a
detached Run").

**Gap.** That commit guarded the orphan evidence with
`solid_queue_execution_live?(run)`, which counted only a queue job whose root is
the Run itself. `RunJob` drives a sequential Workflow depth-first, though: every
Run after the first in an inline chain executes inside the first Run's job and
has none of its own (`chained_run_unprotected`). For those Runs the guard never
fired, so the production failure the commit fixed (a healthy Run failed and
retried in parallel over one orphaned helper) could still happen to any chained
Step. The same Runs also counted as "detached" (no queue job) after a
three-minute heartbeat gap, with their worker alive.

**Fix.** `solid_queue_execution_live?` also counts a live claim whose root is a
workflow-mate that has already finished, which is the RunJob driving the
chain. It never counts a still-running root or attributes anything to a
distributed parallel Run. A chained Run with that claim is not "detached".

**Spec.** `reconciler_spec.rb` "does not fail an inline-chained run as
worker-died while the chain's worker still holds the claim" and "does not treat
an inline-chained run as detached while the chain's worker still holds the
claim" (both failed it before); the sibling spec still passes.

---

## F53. Feedback on a blocked CI repair restarted implementation from the base — fixed

**Found by** deriving the invariant behind a recent main commit ("Rerun
feedback, not implementation, when a feedback workflow is blocked") and checking
the kinds it did not cover (`BlockedFeedback.lean`).

**Property.** Operator feedback on blocked work rebuilds from the base only when
the blocked work was an implementation attempt
(`after_retries_implementation`). Work that lives on the implemented branch is
continued there (`after_keeps_branch`).

**Gap.** `BlockedImplementationFeedback.retry!` asked "is the blocked Workflow a
feedback kind". A blocked CI repair (`ci_failure`), whose `analyze_and_fix`
agent can report `cannot_proceed`, is not a feedback kind, so the feedback
started an implementation retry from the base, abandoning the PR it was
repairing, or was refused while other mutation work was active
(`ci_repair_restarts_from_base`). Rebases and visual reviews never reach this
path (`blocked_workflow` excludes non-approval-blocking kinds), and neither do
landing kinds.

**Fix.** An explicit `Workflow::TriggerKind` field, `builds_from_base`, marks
the implementation attempts (`initial`, `retry`, `base_refresh_retry`). Blocked
work of any other kind, on a Job that has a branch, is retired and the feedback
runs as `chat_feedback` on that branch. Feedback kinds are decided exactly as
before (`after_feedback_unchanged`).

**Spec.** `submit_chat_feedback_tool_spec.rb` "keeps the implemented branch
when the blocked workflow is a CI repair" (refused before);
`trigger_kind_spec.rb` `.builds_from_base?`.

---

## F54. A one-shot landing override bypassed a different blocker of the same kind — fixed

**Found by** DOC-44 Phase 3, landing overrides (`LandingOverride.lean`).

**Property.** An override bypasses only the blocker instance it was granted for
(`after_only_granted`), never a non-overridable blocker, and nothing once used
(`after_respects_gates`).

**Gap.** `LandingQueueProcessor#landing_blocker_override_matches?` compared the
blocker key only. An override stays until it actually unblocks a landing, so one
granted for this Job's CI repair, these inherited failing checks, or that urgent
Job, and never needed, later bypassed a different blocker under the same key
(`stale_override_bypasses`). DOC-44: "Stale overrides cannot bypass a changed
blocker".

**Fix.** Granting an override (app API and the `override_landing_blocker_once`
pending action) records the current blocker's parameters
(`jobs.landing_blocker_override_params`), and the queue matches key and
parameters. The fix only narrows (`after_narrows`). An unused override granted
before this change has no recorded parameters, so it matches only a
parameterless blocker; for anything else the operator grants it again.

**Spec.** `landing_queue_processor_spec.rb` "override binding" (the
other-instance case was bypassed before); the app API grant spec asserts the
recorded parameters.

---

## F55. A late main grade of an older commit cancelled a live CI repair — fixed

**Found by** deriving the invariants behind a recent main commit ("Cancel a
running CI repair whose base main health has moved past";
`BaseSupersession.lean`).

**Property.** A CI repair waiting for its base to be known healthy is released
once the poller observes a different branch head (`after_live`, the commit's
liveness fix), and only on such an observation (`after_safe`).

**Gap.** The commit counted any health check of another SHA after the repair
began waiting. Main grading records its result for the commit it graded, with
`checked_at` set to when it finished, and records `"unknown"` when the SHA is
missing. A full main grade of an older commit that finished after a newer base
landed cancelled a CI repair whose base was the current head and about to be
graded (`late_grade_cancels`).

**Fix.** Only head observations count: CI polls (the poller polls only the
head) and grades of the head the poller last recorded
(`last_health_checked_sha`). The fix only narrows the commit's rule
(`after_narrows`), and it keeps the no-CI case: a grade of the tracked head
still counts.

**Spec.** `ci_repair_safety_spec.rb` "does not count a late grade of an older
commit / a grade recorded without a SHA as main moving past the base" (both
counted before), "counts a grade of the head main health is tracking".

---

## F56. A self-healed merge-train member kept its branch and stacked children — fixed

**Found by** deriving the invariant behind a recent main commit ("Close the PR
and branch of a merge-train member the reconciler lands";
`MemberLandingCleanup.lean`).

**Property.** Every path that lands a merge-train member closes its PR,
retargets its stacked child PRs onto the base and deletes its branch
(`after_uniform`).

**Gap.** `MergeTrainFailureHandler#complete_landing!` self-heals a member the
failed train had already landed. It closed the PR, but neither retargeted
stacked children nor deleted the branch; its own log said "Its branch may still
need manual GitHub cleanup" (`self_heal_incomplete`). The stale-branch reaper
never deletes a branch an open PR targets, so a stacked child kept pointing at
the landed member's branch.

**Fix.** `MergeTrainMemberLandedCleanup` does the land step's cleanup; the
reconciler's member repair (from that commit) and the self-heal both call it.

**Spec.** `merge_train_failure_handler_spec.rb` "retargets stacked children and
deletes a self-healed member's branch" (neither happened before).

---

## F57. A landing validation was reused for an unknown base — fixed

**Found by** DOC-44 Phase 3, validation reuse (`ValidationReuse.lean`).

**Property.** An earlier green landing validation is reused only when every
identity it recorded is matched by a known, equal current one
(`reusable_sound`).

**Gap.** `LandingValidationCache.stale_reason` compared base ref and base SHA
only when the *current* value was known. When the PR payload carried no base
(`LandingValidationCache.decision_for_pr`), a validation recorded against one
base was reused for a base that could be anything, and the landing graders
were skipped (`unknown_base_reused`). The grader-configuration and
changed-file fingerprints already failed closed in both directions.

**Fix.** A recorded base ref or base SHA with no current value is stale
("current base ref is unknown", "current base SHA is unknown"), so the graders
run. Legacy entries that never recorded a base still match on an exact head,
as before. The fix only refuses more (`after_narrows`). It matches NY10: no
landing proceeds on an unknown base.

**Spec.** `landing_validation_cache_spec.rb` "rejects reuse when the current
base SHA / base ref is unknown" (both reused before).

---

## F58. Checkpoint resume continued an older attempt — fixed

**Found by** DOC-44 Phase 3, retry lineage (`CheckpointLineage.lean`).

**Property.** A retry's checkpoint resume continues the attempt being
retried, the Job's newest (`after_newest`).

**Gap.** Every retry (operator and automatic) first tries
`RunCheckpointResume`. Its `source_workflow` took the first failed workflow
that had a resumable checkpoint. A newer attempt that could not be resumed (a
later failure in `implement`) or had succeeded (a feedback workflow that pushed)
did not stop it, so the retry restored and pushed an older attempt's code
(`older_checkpoint_resumed`). Because of F59 it also scanned oldest first.

**Fix.** Only the Job's newest first-class workflow can be the source, and only
if it is a resumable failure; otherwise the retry falls through to an ordinary
retry workflow.

**Spec.** `retry_workflow_enqueuer_spec.rb` "does not resume an older attempt's
checkpoint when a newer workflow succeeded / failed somewhere unresumable" (both
resumed before).

---

## F59. "Newest" lookups on default-ordered associations returned the oldest — fixed

**Found by** deriving the invariant behind a recent main commit ("Return a Job's
newest workflows from the admin API, not its oldest") and finding it was a
class, not one call site (`AssociationOrder.lean`).

**Property.** A lookup for the newest (or highest) record returns it.

**Gap.** `Job#workflows`, `Job#runs`, `Step#runs`, `Workflow#steps`,
`Run#job_logs` and others have a default `order` scope, and `.order(x)` appends
to it: `job.workflows.order(created_at: :desc).first` ran `ORDER BY created_at
ASC, id ASC, created_at DESC, id DESC` and returned the oldest
(`appended_desc_is_ascending`). Forty-one lookups were affected, among them:

- `RunFailureClassifier#recent_logs` (and `AutoRetryFailureClassifier`,
  `ProviderQuotaReset`, `Steps::Base`'s resume-unavailable check) read a run's
  *first* log lines as its recent ones, so a rate limit or provider error at the
  end of a long run went unseen;
- `Workflows::AutoMerge` / `ExternalPrMerge.latest_failed_run` gave the landing
  failure handler the oldest failed run's error to classify;
- the reconciler's retry (`RepairExecutor`) picked the lowest failed step, and
  its run lookup the oldest run;
- `GraderOutcome`, `Workflows::MainGrader`, `FeedbackHandling`,
  `Steps::AnalyzeAndFix`, `BaseRefreshRetryEnqueuer`, `ManualAgenticRun` base
  selection, `RebaseAttemptGuard`, `PollMergeStateJob`, `PollPullRequestJob`,
  the live-state MCP tool, the timeline, coverage reports and more.

**Fix.** All use `reorder`. `spec/architecture/default_ordered_association_spec.rb`
finds every default-ordered association by reflection and fails on any
descending `order` chained onto one, across lines.

**Spec.** `run_failure_classifier_spec.rb` "reads the run's most recent log
lines, not its first ones" and `workflows/auto_merge_spec.rb` "reports the newest
failed run's failure as the landing failure" (both wrong before), plus the
architecture spec (40 offenders before).

---

## F60. A plugin stayed callable on top of a broken hard dependency — fixed

**Found by** DOC-44 plugin host semantics (`PluginClosure.lean`).

**Property.** A contribution is callable only when its plugin and its whole
required dependency closure are healthy (`healthy_iff_closure_sound`, checked
over every acyclic dependency graph on up to four plugins and every choice of
broken plugins).

**Gap.** `Syrus::PluginHealth` degraded a plugin only for a *direct* hard
dependency that was missing or disabled. A plugin whose enabled hard dependency
was itself degraded, failed or incompatible, and therefore had its providers
withheld by `PluginRegistry.providers_for`, stayed healthy, and so did its own
providers (`healthy_over_broken`). The same held along a chain of any length.

**Fix.** `PluginHealth#propagate_unhealthy_dependencies`: an enabled plugin
whose enabled hard dependency is unhealthy is degraded too ("requires b, which
is degraded"), iterated to a fixed point. A disabled dependency is still
reported as before. No bundled plugin is unhealthy in development, so nothing
changes for the default install.

**Spec.** `plugin_health_spec.rb` "degrades a plugin whose enabled hard
dependency is itself unhealthy" and "degrades every plugin above an unhealthy
one along a dependency chain" (both healthy before).

---

## F61. Disabling a plugin stranded its running work — fixed

**Found by** DOC-44 plugin host semantics (`PluginDisableRecovery.lean`).

**Property.** Disabling a plugin never leaves work that cannot be finished or
cancelled: in every reachable state, every active workflow's and step's kind is
installed (`active_kinds_installed`, checked over every sequence of up to five
disable/enable/create/finish actions on two plugins and four kinds).

**Gap.** Two layers.

* `Job`, `Workflow`, `Step` and `Run` validated their kind against the live
  kind registry on every save. Disabling a plugin tears its kinds down, so
  after an operator disabled, say, `agent_insights` with a sweep running,
  `step.update!(state: "cancelled")` and `WorkUnits::WorkflowCancellation`
  both raised `RecordInvalid: Kind is not included in the list`
  (`stranded_before`).
* `Admin::PluginDisableGuard` had no blocker for active work of the plugin's
  own kinds, so nothing stopped the disable. Fixing saves alone is not enough:
  `Workflow#work_definition` and the step handler resolve through the same
  registry, and cancellation cascades raise `WorkDefinitions::UnknownKind`
  (`unguarded_disable_strands`).

**Fix.**

* Kind inclusion is checked on create and on a kind change only
  (`new_record? || will_save_change_to_kind?`), so an existing row keeps the
  kind it was created with (`existing_saves`). A new row, or a changed kind,
  still has to name an installed kind (`new_rows_checked`).
* `PluginDisableGuard#workflow_kind_blockers` blocks the disable while a queued
  or running workflow of the plugin's trigger kinds, or an active step of its
  step kinds, exists, like the existing active-workflows check for agent
  providers. Open Jobs of its Job kinds do not block, because a failed Job
  stays open indefinitely and needs no handler to be closed.

**Spec.**

* `spec/models/plugin_kind_persistence_spec.rb`: cancelling a running step of a
  disabled plugin's kind raised before the fix.
* `plugin_disable_guard_spec.rb` "workflow kind providers": both blocking
  cases were allowed before the fix.
* `spec/architecture/kind_writes_validated_spec.rb`: no app write sets a kind
  around validation, which the model's "create only if installed" step relies
  on.

**Remaining.** Health degradation also withholds a plugin's providers, kinds
included, and there is no operator action to guard. That is NY14.

---

## F62. An unhealthy plugin's effects stayed installed — fixed

**Found by** DOC-44 plugin host semantics, "partial plugin registration cannot
survive boot failure" (`EffectHealth.lean`).

**Property.** Every contribution channel uses the same callable gate. The
plugins whose `while_enabled` effects install are exactly the plugins whose
providers `providers_for` hands out, which is the plugins that are enabled and
whose whole required closure is enabled and sound
(`channels_agree_and_effects_iff_closure`, checked over every acyclic graph on
up to three plugins, every enabled set and every broken set).

**Gap.** `Syrus::Installer` installed a plugin's `while_enabled` effects
whenever the plugin was switched on, ignoring health. Effects are
contributions: chat session rehydrators (the agent plugins), credential probes
(video walkthroughs), and Coworkers' chat, search and schedule extensions. So a
plugin that was degraded, or sat on a broken dependency, kept its code callable
through its effects while its providers were withheld
(`effects_outran_providers`).

This also left a partial-registration hole. `Definition#install!` registers the
manifest, then calls `Installer.define` for each effect, then runs boot
blocks. When a boot block raises, `PluginLoader.install_definition!` restores
the registry snapshot and records the plugin as failed. The effect
registrations are not in that snapshot and survive the restore. The failed
manifest keeps the operator's enabled flag, so the effects of a plugin that
failed to boot were installed (`failed_load_effects`).

**Fix.** `Installer.enabled_plugin_names` keeps only enabled plugins that
`PluginRegistry.health` reports healthy. This is the same filter as
`providers_for`. `ever_enabled` cleanup effects are unchanged, because they
exist to tidy up after the plugin. A health change that comes from a
`PluginRecord` toggle bumps the generation, so effects are torn down on the
next sync.

**Spec.** `installer_spec.rb` "unhealthy plugins": a degraded plugin, and one
whose load failed, installed their effects before the fix. A plugin turning
degraded now disposes its effects and does not reinstall them.

---

## F63. Plugin CLI command collisions were decided by plugin names — fixed

**Found by** DOC-44 plugin host semantics, "Plugin CLI command collisions fail
deterministically" (`CliCollisions.lean`).

**Property.** No offered CLI command collides with another plugin's command,
so every offered command is reachable, whatever order the plugins are mounted
in (`all_offered_reachable`, checked over every set of commands on two plugins
with paths of up to two words).

**Gap.**

- `CliCommand.normalize_all` rejected duplicate paths only within one plugin.
- The Go CLI (`registerPluginCommands`) mounts catalog commands at their bare
  path, first entry wins. A later command is skipped when its path already
  holds a command, or a group made for a longer path.
- `PluginCliCommands.catalog` sorts by plugin name.

So when two enabled plugins declared the same path, the plugin whose name
sorted first owned it, and the other's command silently vanished. A rename
flipped the owner (`owner_follows_names`). The same held when one plugin's path
was a prefix of another's: if `beta`'s `docs list` sorted first, `docs` became
a group and `alpha`'s runnable `docs` vanished (`prefix_vanishes`). No health
signal said so.

**Fix.**

- `CliCommand.collisions` treats two commands of different plugins as
  colliding when one path equals, or is a prefix of, the other.
  `PluginCliCommands.catalog` withholds every command in a collision.
- `PluginHealth#warn_cli_collisions` adds a `:warning` to both plugins ("CLI
  command `docs list` collides with beta's `docs`; neither is offered"). It
  uses the same enabled-and-healthy set the catalog draws from, and a warning
  never changes health.
- A plugin's own nested commands never collide. Built-in commands still win,
  as before (`TestCompiledCommandWinsOverCatalogCollision`).
- No bundled plugin collides (20 commands checked), so nothing changes for the
  default install. Documented in `docs/engineering/conventions/plugins.md`.

**Spec.** `spec/services/plugin_cli_commands_spec.rb`:

- same path and prefix collisions were both offered before the fix;
- the health warning was `:ok`;
- a disabled plugin does not take a path away.

---

## M1. Required reviews vs. the HEAD that is pushed — modelled, by design (NY1: C)

**Decision (2026-11-20).** Agent-authored commits after approval are intended.
They only happen as part of fixes and rebases (`landing_fix`, agent conflict
resolution), which graders cover, so there's no re-review gate. The proved
property below is the barrier's whole guarantee.

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

## M3. The landing validation gate — proved, no bug

`ValidationGate.lean` mirrors `LandingValidationManifest.verify` and
`.evidence_for`, the gate `AutoMerge` and `MergeTrainLand` consult before
merging. For every manifest it proves:

- a manifest without a required result never passes (`ok_has_required`), so
  advisory evidence cannot replace required evidence;
- every required result passed with command and environment fingerprints
  (`ok_required_passed`), so infrastructure failure, inconclusive, cancelled
  or missing results never pass (`infra_never_passes`);
- under exact-head binding, the manifest, its snapshot and every snapshotted
  required result are for the landing SHA (`ok_exact_current`);
- only a manifest recorded for the landing SHA is consulted
  (`evidenceFor_ok_current`), never one for another SHA with the same tree.

`landing_validation_manifest_spec.rb` "accepts exactly the target shapes the
model accepts" checks Ruby against the model's per-target rule over every
outcome, source SHA, fingerprint, requiredness and binding (144 shapes).

Trust boundary (`reused_not_sha_checked`): carried-forward and target-health
results have no source SHA, so the gate accepts them on fingerprints alone.
Their applicability is decided upstream by `Steps::GraderFanout`, which reuses a
result only when the target's fingerprints or health record still match. That
reuse decision is modelled in `RepairReuse.lean` (F50).

---

## M4. Retry budgets across retry paths — proved, one question (NY11)

`RetryBudget.lean` compares the two paths that create `AutoRetryAttempt`s for
an ordinary failed Run. In-place attempts count against the reconciler's
job-wide budget for the same (job, provider, classification)
(`reconciler_respects_in_place`). So a Step that used its in-place retries gets
no more from the reconciler (`job_bound`): switching from one path to the other
does not bypass the budget.

The in-place path's own budget is per Step (`in_place_per_step`), so a Job can
take `MAX_ATTEMPTS` in-place retries of one classification on every Step, each
Step bounded (`step_bound`). `run_spec.rb` "gives each Step its own in-place
budget for transient Git transport failures" pins that. NY11 (decided A):
kept per Step. Infrastructure failures should fail work as rarely as possible
while runaway loops stay bounded, and each Step's budget is.

---

## M6. Force pushes never overwrite an unobserved remote update — proved, no bug

DOC-44 Phase 3, Git boundary. `ForcePushLease.lean` models the three lease
forms Syrus pushes with, and `spec/lib/git_force_with_lease_semantics_spec.rb`
pins their behaviour against real git (a bare repository, two clones). An
explicit lease succeeds only while the remote is the SHA Syrus observed; an
empty expectation only while the branch does not exist; a bare lease against a
URL refuses once the branch exists ("stale info"). Every explicit SHA is one
Syrus observed before it rewrote (`ls-remote`, or the tip right after fetching
and before any agent ran), so an accepted push replaced exactly what Syrus saw
(`accepted_replaces_observed`) and any later update makes it fail
(`unobserved_update_rejects`).

`Steps::StackForcePush` falls back to a bare lease when an entry has no
`pre_sha`. `StackAgentRebase` always records one, and the bare form fails
closed anyway (`bare_never_overwrites`). The one plain `--force`
(`Steps::MergeTrainBuild`) publishes a train's freshly built integration
branch, which only that train writes.

---

## M7. Database boundary for lock exclusivity — pinned, no bug

The lock models (`LockSafety.lean`, `LockAcquire.lean`) assume at most one
active `WorkUnitLock` per key. The model validation runs before the insert, so
two concurrent acquirers can both pass it. The unique index
`idx_work_unit_locks_active_key_unique` on `active_lock_key` is what rejects the
second, and `release!` clears that column with `released_at`.
`work_unit_lock_spec.rb` now pins both against the database with validation
skipped, as in the race. `spec/architecture/work_unit_lock_release_spec.rb`
fails if any code writes `released_at` with a bulk or callback-skipping write
that would leave the key taken; none does today. The other uniqueness
assumptions in the models are already pinned at the database:
`retry_workflow_uniqueness_key` (`auto_retry_attempt_spec.rb`), external PR
number, merge-train membership and position.

---

## M8. Merge-train membership, order and Epic atomicity — proved, no bug

- `TrainOrder.lean`: `LandingQueueProcessor#dependency_order` (Kahn's algorithm,
  original-order ties, cycle fallback) is transcribed and checked over every
  dependency graph on up to four members. It always returns exactly the members
  (`order_is_permutation`), and for an acyclic graph every prerequisite comes
  first (`order_respects_dependencies`).
  `landing_queue_processor_dependency_order_spec.rb` checks the Ruby method for
  the same over 500 random graphs. The dispatchers store this order as member
  positions and `Steps::MergeTrainBuild` integrates `train.member_jobs` by
  position, so the integration content is the declared members in dependency
  order.
- Partial success is not reported as atomic: a landed train with unverifiable
  members is `succeeded` (its integration merge is atomic) but records a
  `partial` member reconciliation and leaves those members open for the
  reconciler, so their Epic cannot close early.
- `EpicAtomicLanding.lean`: both landing entry points route an Epic child to its
  train before the per-Job path, so `land` is never reached for one
  (`epic_child_never_lands_alone`), even though `waiting_epic_merge_train` is an
  overridable blocker. Pinned by "never lands an Epic child on its own, even
  with an override of the train wait".

---

## M9. An "ask" decision never becomes implicit approval — proved, one question (NY12)

DOC-44 Phase 4. `AskNeverApproves.lean` models the policy combination and the
three MCP gate paths (`Mcp::Tools::AuthorizationSupport.authorization_gate`):

- `Permissions::PolicyEvaluator`: a matching deny in any layer is decisive
  (`any_deny_wins`). Matching and scope-normalization failures fail closed,
  over-broad allows are inert, and non-delegable rules cap the result.
- Scheduled runs (`ScheduledAuthorization`): on `ask`, every routing outcome
  (created, reused, denial cooldown, request cap) returns a response instead of
  running the tool.
- Chats (`AuthorizationRequest`): `ask` always yields a request, either an
  equivalent existing one or a new one, so the gate's "no request means
  authorized" branch is reached only on `allow`.
- Tools whose effect is the owner's confirmation card (`approval_effect`, or a
  tool registered as a pending action): `deny` raises, and `ask` runs the tool,
  because what it does is create that card.

Proved: a deny never runs a tool (`deny_never_runs`), and `ask` runs one only
when its effect is a confirmation card (`ask_runs_only_confirmation_tools`).
`authorization_support_spec.rb` already pins each path. No bug found. The trust
boundary: `approval_effect` is a declaration, and a plugin tool definition can
make it (NY12).

---

## M10. Permission leases stay within their grant — proved, no bug

DOC-44 Phase 4. `LeaseScope.lean` models `PermissionLease#available?` and
`LeaseAuthorizer`'s consumption. Leases are loaded per owner, capability and
operation under a row lock and consumed in the same transaction. An available
lease is unrevoked, unexpired, has uses left, grants every effect of the
invocation, matches its constraints, and belongs to the caller's instance: the
exact invocation fingerprint (single use), the same live chat session, or the
same non-terminal Job (`available_sound`). It then enters the evaluator as a
rule carrying its subject selector and resource scope, so another actor or
resource does not match. Consumption never exceeds `max_uses`
(`consume_bounded`). Revocation also invalidates unclaimed authorized
invocations. One observation: a Job-scoped lease becomes usable again if its
closed Job is reopened, which reads as intended (same thread, same grant).

---

## M11. Scope matching and approved-invocation claims — proved, no bug

DOC-44 Phase 4.

- `ScopeMatching.lean`: `PolicyRule#match_status` matches a rule only when the
  invocation's normalized scope is `equal` to or `narrower` than the rule's,
  and `ResourceScopeSchema#compare` fails closed on any normalize or compare
  error. Under set semantics a matching rule covers every resource of the
  invocation (`match_within_scope`). A `string_prefix` constraint compares
  whitespace tokens, so `git commit` does not match `git commitfoo`
  (`prefix_tokens`, `no_raw_text_prefix`). A rule with no scope is family-wide,
  and an allow that broad is capped by the descriptor's breadth ceiling. The
  guarantee rests on each provider's normalize and compare callbacks being right
  for their scope type.
- `InvocationClaim.lean`: an approved tool call is an `AuthorizedInvocation`
  claimed once, under the row lock, only from `issued`, only with the approved
  fingerprint, only while the originating action is still confirming, and only
  if authority still holds when re-evaluated at claim time (`claim_requires`,
  `claim_once`). The tool gate then requires the same claim key, claimant, tool
  and fingerprint, and revocation invalidates unclaimed invocations. So authority
  is checked when the effect becomes possible, and a retry cannot reuse a spent
  approval.

---

## M12. Delegated approval and audit evidence — proved, no bug

DOC-44 Phase 4. `ApprovalDelegation.lean` models
`Permissions::ApprovalProviderAuthorizer` and `ApprovalProviderLifecycle`. A
provider may decide a request only if:

- it is not `syrus.permissions` and has no core human-only effect (`financial`,
  `privilege_change`);
- an active delegation covers it: same capability and resource type, every key
  of the delegation's scope present and equal (a non-empty subset for list keys),
  and no excluded effect, the human-only ones always excluded;
- no non-delegable rule stands above `allow`;
- the provider's confidence is at least 0.8.

The approval is recorded with `invocation` duration and issues one
`AuthorizedInvocation`, so a delegated approval never becomes standing
authority (`delegated_within_authority`). A list-scoped delegation never covers
a request outside its list (`list_scope_subset`).

"Audit evidence records the decision actually used" holds by construction:
`Permissions::Management#authorize` passes the same decision object it returns
to `DecisionAudit.record`.

---

## M13. Optional dependencies never disable a plugin — audited, no bug

DOC-44 plugin host: "Optional dependency absence cannot disable the dependent
plugin." `optionally_depends_on` has three ways in which it could act, and all
three follow hard edges only:

- **Health:** `PluginHealth#status_for` and the F60 propagation read
  `depends_on` only. A plugin stays `ok` when an optional dependency is
  missing, disabled or unhealthy.
- **Load:** `PluginLoader#load!` and `install_definition!` skip a plugin only
  for a failed `required_dependencies` entry. A plugin whose optional
  dependency raised in `on_boot` still loads, and its providers are handed out.
- **Cascade:** `Admin::PluginDependencyGraph` walks `depends_on` only.
  Disabling an optional dependency does not cascade to the plugin that uses it,
  and enabling a plugin does not pull its optional dependencies in.

The property is structural (no code path reads optional edges for any of these
three decisions), so it is pinned by specs rather than a Lean model:
`plugin_health_spec.rb` "leaves a plugin ok when an optional dependency is
disabled or unhealthy", `plugin_loader_spec.rb` "still loads a plugin whose
optional dependency raised during boot", and `plugin_dependency_graph_spec.rb`
"ignores optional dependencies in both directions". Whether an absent optional
capability then has an explicit neutral behaviour is the separate
`defined?(X) && X.enabled?` guard, covered by the next property.

---

## M14. Missing execution backends and the local default — audited, one question

DOC-44 plugin host: "Missing contributions never silently select core defaults
where behaviour would change," and "Plugin capabilities still pass core
authorization."

`Execution::Router#backend_for` is the one place in core where a missing
contribution selects a core default: when no enabled, healthy
`:execution_backend` answers `available_for?`, the command runs through
`Execution::Local`. Checked:

- **Authorization:** the fallback is never silent about authority. The router
  authorizes the backend it actually picked, with location `:host` for
  `Local` and `:container` otherwise, and anything but an explicit allow
  raises `NotAuthorized` before a process starts. An `ask` fails closed.
- **Fail-closed workloads:** the only fail-closed workload is
  `Execution::ChatWorkloadPolicy` under `contained_chat_execution: required`.
  The policy is read live per request, so a database error while reading it
  propagates out of the rescue instead of falling back to local.
- **Who carries the policy:** chat agent turns (`ChatTurnJob`) and Coworkers
  runs attach it.

One path does not: Coding Mode `!` shell commands
(`ChatShellCommandExecutor::Coding`) go through `ProcessRunner` with no
workload policy. Under `required` they run on the worker while the chat agent
is contained, in the same checkout the agent writes. That is NY15.

`providers_for`'s own database-error fallback hands out disabled backends too.
That is the NY13 question again, not a separate one.

---

## M5. Invariants derived from recent main commits

At the operator's request, each recent main commit that touches engine
behaviour was read for the invariant it restores, then checked for places that
invariant still fails.

- "Do not declare a worker dead over one orphaned helper process": a Run that a
  live claim is executing is never failed as `worker_died`. **Violated for
  inline-chained Runs: F52**, now proved (`WorkerEvidence.after_complete`).
- "Rerun feedback, not implementation, when a feedback workflow is blocked":
  feedback on blocked work never abandons an implemented branch. **Violated for
  blocked CI repairs: F53**, now proved (`BlockedFeedback.after_keeps_branch`).
- "Make the chaos simulation's stranded step genuinely resumable": a queued
  Step resumes only once every dependency edge is settled (not its
  linked-list predecessor). Holds, proved in `EdgeReadiness.lean`: the
  reconciler's resume readiness implies the dispatcher's
  (`handoff_implies_settled`), and a finished predecessor alone does not ready
  a Step with explicit edges (`predecessor_not_enough`, the chaos case). The
  commit fixed the test's topology, not the engine.
- Review workspace ("Harden Review workspace freshness"): an approval or
  feedback from the workspace applies only to the Job revision the operator
  reviewed. Holds: both send `expected_revision` and the app API rejects a
  mismatch (`reject_stale_job_revision?`); `entity_revision` bumps on every Job
  save, and every change to the reviewable diff passes through a Workflow whose
  state transitions save the Job. The callback-skipping `update_column` writes
  touch only post-landing fields (`landed_sha`, `branch_deleted_at`). Proved in
  `ReviewRevision.lean` under that audited assumption: an accepted decision acts
  on the reviewed diff (`accepted_acts_on_reviewed_diff`).

The remaining commits (UI, syntax highlighting, spec speed-ups, CI sharding,
admin query counts) state no engine invariant.

Later commits, checked in the next iteration:

- "Cancel a running CI repair whose base main health has moved past":
  violated by late grades of older commits, F55; proved in
  `BaseSupersession.lean`.
- "Close the PR and branch of a merge-train member the reconciler lands":
  violated by the failure handler's self-heal, F56; proved in
  `MemberLandingCleanup.lean`.
- "Keep parallel RSpec preflight graders on their own test databases":
  concurrent graders never share a test database and cleanup never deletes
  another grader's files. Holds, checked exhaustively in
  `TestDbNamespaces.lean` (`suffix_injective`, `cleanup_scoped`).
- "Return a Job's newest workflows from the admin API": first read as
  presentation only. Its invariant (a "newest" lookup returns the newest) turned
  out to fail in 41 places: F59, proved in `AssociationOrder.lean`.

- "Prevent long diff filenames from widening step views": a CSS-only layout
  fix whose invariant (a file row never widens the page) is geometry, pinned by
  its own `ReviewableDiff.test.tsx` regression; no engine state involved.

Checked through main `d7403fee64`. Each loop iteration continues from there:
new commits on `origin/main` that are not this branch's, their invariants,
and a proof or a counterexample and fix for each.

---

## Open questions for review

- **Q1 — resolved as F7** (fail and hold instead of parking).
- **Q2 — resolved as F5 + F6** (no rebase for children landed with their
  parent; deferred closure, no step starts for a closed Job).
- **Q3. Admin WorkUnits list 500s past page 29** (`Mysql2: Out of sort memory`)
  — found while paging it read-only for O1; not engine-related.

## Pre-existing failures to fix

- **Fixed:** `spec/jobs/run_job_parallel_grader_projection_spec.rb:55`
  (ci_only). Only one of the two grader Steps got a Run.
  `GraderFanoutAdmission` falls back to this host's derived capacity when no
  worker heartbeat is live, which came out at 1 on this machine. It admitted
  alpha and deferred beta (`released_count: 1`). The spec predates admission
  control, so this is a test bug, not an engine bug. It now pins
  `RunHostAdmissionCapacity.host_compute_capacity`, as `step_dispatcher_spec`
  already does. It passes in CI whenever the runner's capacity is ≥ 2.

## F22. Retries of a superseded loop iteration revived a stopped Workflow hourly — fixed

**Property.** Retry, resume and continue-loop work target only a loop's latest
iteration. Once iteration k+1 exists, iteration k's outcome has already been
acted on (`Agreement.iter_after_actionable`).

**Evidence (production, read-only; a retry Workflow on 2026-11-16, Eastern).**
- 09:01: the iteration-1 `grader_collect` Run failed with a retryable
  classification. An `AutoRetryAttempt` was created for it, and the loop went on
  to iterations 2 and 3.
- 09:39: iteration 3 decided `grader_loop_no_progress`. The Workflow failed,
  deliberately.
- Every minute after that, the reconciler's `retryable_run_failure` planned
  `retry_failed_step` for the *iteration-1* Run. Each plan was skipped with
  "retry already pending".
- 10:05: the pending retry fired. It re-ran that superseded collect, which
  reopened the stopped Workflow. The loop then decided `no_progress` again and
  the Workflow failed again, and the re-run's failure scheduled the next retry.
  The cycle repeated about hourly until 17:15: 12 Runs on the old collect, and
  9 "applied" continue-loop repairs on the iteration-3 collect.
- 17:56: the next iteration started, and the Workflow succeeded at 18:18.

**Counterexample.** `iter_before_not_actionable`: nothing asked whether a failed
Step had been superseded by a later iteration of its loop. The existing
supersession checks only covered retry-until barriers, manual restarts and
try-branches.

**Fix.** A new `Step#superseded_by_later_loop_iteration?` (indexed query on
workflow, loop_id and iteration). It is used by:
- `AutoRetryAttempt#stale_pending_reason`, so the pending retry is skipped and
  pruned. That breaks the cycle.
- `orphaned_failed_step` (running Workflows only), which closes the classifier
  gap where a failed iteration superseded by a passing one looked orphaned
  between two later Steps.

**Deliberately not applied: the reconciler's failed-Run retry classifiers.** I
first added the guard to all five. The merge-train simulation scenario
`terminal_bundle_train_final_fix_rebuilds` then stopped converging. There, the
workflow-level remedy (`rebuild_merge_train`) is planned from the retryable
failure of an *earlier* iteration's grader, and the latest iteration's failure
only plans operator review. Those classifiers choose a Workflow-level repair,
not a re-run of that Step. The guard belongs on step-level re-runs only.

**Specs.**
- `auto_retry_attempt_spec.rb`: pruned when superseded (red before), and kept
  for the latest iteration.
- `reconciler_spec.rb`: "does not treat a failed loop iteration a later one
  superseded as orphaned" (red before).

**Also fixed here.** `chat_pending_action_spec.rb:595` (ci_only) had failed
since F15. Its fixture failed a Step with `update_columns` but left the Step's
Run queued, a state the engine can't produce, and F15's guard then refused the
retry. The fixture now fails the Run as well. Earlier wide runs missed this
because they didn't set `RUN_CI_ONLY_SPECS`.

**Not explained.**
- Why each re-run of the old collect failed within a second as `worker_died`.
- 31 repairs crashed during 30 minutes on 2026-11-14 with
  `NoMethodError: undefined method 'step_agent_diff' for an instance of Run`.
  The method has existed since 2026-11-10 and the error has not recurred.
  Version skew during a deploy is likely but unconfirmed.

---

## Lead L2: lock-wait timeouts on two hot rows (production, read-only)

**Counts.** No InnoDB deadlocks in 7 days. There were 33 lock-wait timeouts
(MySQL's default wait is 50 s): RunJob 13, PollMergeStateJob 8,
PollPullRequestJob 6, the rest scattered. All sampled backtraces are *waiters*:
- **Workflow row (5).** `StepDispatcher.create_run_and_enqueue` → `Workflow#reload`
  (with lock) while advancing a chain. Four hit between 22:08 and 22:41 Eastern
  on 2026-11-19, a period with heavy merge-train grading.
- **User row (3).** `AppEvents.next_sequence` → `UPDATE users SET
  app_event_sequence = app_event_sequence + 1`, from a Job commit callback.
  Every app broadcast for a user serialises on that user's row. With
  effectively one operator, that is every broadcast in the instance.
- **Others:** `PollPullRequestJob#cache_pr_checks_state` (2),
  `GraderFanoutAdmission.synchronize` (1), `ReapOrphanedSpawnedProcessesJob` (1).

**Likely holders, not yet proven.**
- `GraderFanoutAdmission.synchronize` holds the *instance-wide* `AppSetting`
  row lock while it creates and enqueues every admitted grader Run, and each
  creation takes that Workflow's lock and runs RunQueueResolver. A merge train
  admits about 80 graders.
- Any broadcast made inside a longer transaction holds the user row until that
  transaction commits.

Next: find the holders, from the `innodb_lock_waits` view at a timeout, or by
timing the admission block.

**Code-level hazard found while looking.** `LandingValidationPrefetcher#call`
locks the source landing Workflow and the target Jobs, then runs
`LandingValidationPrefetchSource.publish!` inside that transaction:
- `git bundle create … HEAD`, a bundle of the whole repository;
- the ActiveStorage upload of that bundle.

It runs "after landing graders passed", exactly when that Workflow's grader
Runs advance and need its lock. Its errors are rescued and only logged.

I could not tie it to the 2026-11-19 burst: no prefetch Workflow started
22:00–22:45, and operational logs are kept only 6 hours. The fix would be to
build and upload the bundle outside the lock, then claim and attach under it,
purging the blob on a lost race. Left until a holder is proven.

**Lock order.** Retry (`RetryFailedStepEnqueuer`: Job lock → reopen Workflow)
and `WorkflowCancellation` (Workflow lock → cancel → Job write) take Job and
Workflow in opposite orders. That cycle can deadlock but did not fire in 7
days.

## Fixed: the order-dependent terminal-relay specs

`runtime_terminal_lifecycle_spec.rb` (3 examples) failed only when the full
suite ran serially. `rspec --bisect` isolated a single earlier example,
`chat_turn_job_spec.rb` "includes the workspace root and attached job context
in the coding mode prompt".

**Mechanism.** About 171 of 208 core MCP tool classes get their authorization
dispatch (`AuthorizationSupport::ToolDispatch`) only when
`Mcp::Sidecar.authorize_tool` runs on them. It prepends to the class
permanently, the first time a sidecar tool list is built in the process. A chat
turn builds one. The spec called `RuntimeStartTool` and friends directly, so
alone they ran ungated. After a chat turn they were gated, and with no
permission grant `runtime_start` returned an authorization request instead of a
session.

**Fix.** The spec now runs the way production does: it wraps its seven runtime
tools with `authorize_tool` and opts into `full_chat_access: :all`. It passes
alone and after the polluting example.

## Lead L3: whether a tool call is gated depends on process history (closed by F46, F47 and NY9)

The same mechanism has a production side. Sidecar and daemon dispatch wrap a
tool before calling it, so real agent tool calls are gated. But any in-process
code that calls a core tool class directly gets the authorization check only if
something in the same process already built a sidecar tool list. Static
wrapping, as about 37 tools already do in their class body, would make gating
independent of load history. Not yet checked: whether any production caller
invokes tool classes directly.

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
- **D3.** Main-branch repair uniqueness (DOC-44, "at most one active repair
  owner per broken-main episode"). `MainHealthChangedService#ensure_repair_job!`
  checks for a blocking repair Job, then creates one, with no lock. It has many
  callers: the health poll, the landing queue, the main grader, the repair
  Workflow and the operator endpoint. Two creators that read the same snapshot
  pick the same title-derived slug (`Job#generate_slug`), so the unique slug
  index rejects the second one, as the rescue comment says. One interleaving
  gets past it: B checks for a blocking Job before A commits, and picks a slug
  after A commits, so B takes the next suffix. Production (read-only, the
  repair Jobs since 2026-10-10) shows overlapping repair Jobs, but they are
  failed repairs left open under `MAX_OPEN_FAILED_FIX_JOBS`, none created
  within seconds of another. A repository row lock would close it, at the cost
  of a new lock in a path with known lock-wait pressure (Lead L2). Left as is.
- **D4.** Landing deferral vs rejection (DOC-44, "Deferral preserves approval
  only for declared transient classes"). `LandingFailureHandler` maps a
  declared Problem first, but a known non-retryable Problem that is not itself
  a landing code (`grader_failure`, `git_failure`) falls through to
  pattern-matching the free-text reason, so its text can still classify it
  transient. For landing-grader failures the reason is "required graders
  failed:" plus grader names, not their output, so test output cannot reach
  the patterns. Making the Problem decisive would turn a `git_failure` whose
  text is a dropped connection from a deferral into a rejection, so the text
  fallback stays. Left as is.
- **D5.** Contribution key ownership (DOC-44, "Contribution keys have one
  unambiguous owner and resolution is deterministic"). `Syrus::KindRegistry`
  never lets a plugin shadow a built-in kind. When two plugins declare the same
  kind, the first in `providers_for` order wins and the other is logged and
  ignored. That order is deterministic for a given plugin set: `PluginLoader`
  loads in dependency layers sorted by name, and `providers_for` sorts by
  `prepare_priority`, breaking ties by registration index. It is not stable
  across plugin sets, though: installing a plugin that sorts earlier and
  declares an existing plugin's kind takes that kind over (existing Workflows
  of that kind would then resolve to the newcomer's template) with only a log
  line. No bundled plugins collide. Rejecting a contested key for both plugins
  would be the strict reading; left as is.

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
