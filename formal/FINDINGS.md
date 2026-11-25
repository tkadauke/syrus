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

## F64. Renaming a permission operation dropped its stored deny rules — fixed

**Found by** DOC-44 plugin host semantics, "Permission upgrades and scope
migrations cannot broaden authority unless the expansion is explicit"
(`RuleAliases.lean`).

**Property.** A rename that keeps the old identifier as an alias changes no
authorization decision. This holds for every list of up to three rules stored
before the rename, every policy and every role default
(`rename_preserves_decisions`).

**Gap.** `Syrus::Plugin::PermissionProvider` is public plugin API. It lets a
plugin rename a capability or operation and list the old identifier in
`capability_aliases` or `operation_aliases`. `CapabilityUpgradeValidator`
accepts that as the same capability, needing no scope migration and causing no
widening.

Stored permission rules keep the identifier they were written with, but
`PolicyRule#match_status` compared identifiers literally. So the moment a
plugin renamed `…/write@v1` to `…/write@v2`, an operator's repository-level
*deny* for `@v1` stopped matching, and the role default decided. With an
`allow` default, the denied action became allowed (`rename_turned_deny_into_allow`;
the spec saw `allow` where `deny` was expected). The admin permission matrix
filtered the same way, so it displayed the default too. No bundled plugin uses
aliases yet, so this was latent.

**Fix.** `CapabilityDescriptor#names_capability?` and `#names_operation?` treat
an alias as the identifier. `PolicyRule#match_status` uses the descriptor's
aliases, and `Permissions::Management#matrix_state` uses the same helpers, so
the display matches what is enforced. A rule naming an identifier the
descriptor never had still does not match (`foreign_rule_ignored`).

**Also checked.**

- `CapabilityScopeMigration` transforms are validated but never applied at
  runtime. No plugin declares one.
- `validate_permission_upgrade!` runs only in the plugin-author test kit.

So "scope migrations cannot broaden" holds vacuously today. Once a migration is
first used, its transform will need a runtime caller, and that caller will need
the same property.

**Spec.** `policy_evaluator_spec.rb` "renamed capabilities and operations":
stored denies for the old operation and the old capability were `allow` before
the fix. An unrelated identifier still does not match.

---

## F65. Queued plugin callbacks ran against a state that had moved on — fixed

**Found by** DOC-44 plugin host semantics, "A plugin is never called for a
capability it did not declare" and "Disable affects new resolution"
(`LifecycleOrder.lean`).

**Property.** For every sequence of up to four enable and disable toggles from
either starting state, and every order in which their queued lifecycle jobs
run, a plugin ends with live effects exactly when it ends enabled
(`converges`).

**Context.** Core reaches plugin code through `providers_for`, which hands out
only enabled and healthy plugins, except for a few call sites that read
`manifest.provides` directly. Two of those ran plugin code from a queued job
without checking that the state that enqueued them still held:

- `PluginTickJob` called `on_tick` for whatever plugin it named. Its scheduler
  checks enablement and health when it enqueues, but the tick can wait in
  `control_plane` while the plugin is disabled or turns degraded, and it then
  ticked anyway.
- `PluginRecord` enqueues `on_enable` or `on_disable` after every toggle, and
  the queue does not order those jobs against a later toggle. After an
  enable then disable, a late `on_enable` registered effects that nothing
  drained, so a disabled plugin held live effects until it was next disabled
  (`stale_enable_strands`). After a disable then enable, a late `on_disable`
  drained the effects of an enabled plugin.

**Fix.**

- `PluginTickJob` returns unless the plugin is enabled and healthy, the
  scheduler's own condition.
- `PluginLifecycleJob#stale?` skips an `on_enable` for a plugin that is
  disabled now, and an `on_disable` for one that is enabled now. The toggle
  that made the job stale enqueued its own event, which then does the work.
- `on_boot` and `on_shutdown` are process events and are unchanged.

**Spec.**

- `plugin_lifecycle_job_spec.rb` "stale events", and "does not drain an
  enabled plugin's effects for a stale on_disable".
- `plugin_tick_job_spec.rb`: a disabled plugin and a degraded plugin each
  ticked before the fix.
- Three existing examples ran `on_disable` against a plugin that was still
  enabled. They now disable it first, which is the order production uses.

**Note.** `Syrus::Plugin::EffectRegistry` is process-local, so `on_enable`
effects registered in one worker are drained only by an `on_disable` in the
same process. That design limit predates this fix, which does not change it.

---

## F66. Plugin-hosted extension points ignored health — fixed

**Found by** DOC-44 plugin host semantics: auditing every call site that reads
`manifest.provides` instead of going through `providers_for`.

**Property.** This is `EffectHealth.lean`'s single callable gate, enabled and
healthy, applied to a third channel: points one plugin hosts for others
(`"<host>:<point>"`, such as `connected_accounts:provider`).

**Gap.** `PluginRegistry.hosted_providers_for` required only `enabled?`, of
the host and of each contributor. A contributor that was degraded, failed to
load, or sat on a broken dependency still contributed. That included a
contributor its host had rejected through `add_validation_error`, which is the
documented way a host degrades a malformed contribution. A degraded host kept
serving its point too.

**Fix.** `hosted_providers_for` computes the same enabled-and-healthy set as
the core points, using `health_for` over the enabled plugins. It requires the
host to be in that set, and takes contributions only from plugins in it.

**Spec.** `plugin_registry_spec.rb` "withholds a hosted point's providers from
an unhealthy contributor" and "withholds every provider of a point whose host
is unhealthy" (both returned the provider before the fix). Plugin, lib and
admin specs pass (7,412 examples), and `bin/check-plugin-boundaries` is clean.

**Audit of the other direct `manifest.provides` readers.**

- *Deliberate:*
  - `PlatformPollingJob` only identifies a class.
  - `RepoPluginDetector` asks disabled plugins to detect, so it can recommend
    enabling them.
  - `PluginRepositoryConfiguration` labels each registration
    enabled, disabled or unavailable, and offers only enabled ones.
  - `Syrus::Events#queue_for` picks a queue.
  - `PluginDisableGuard` and `Permissions::PluginContributions` take inventory.
- *Fixed in F65:* `PluginTickJob` and `PluginLifecycleJob`.
- *Still enabled-only:* two plugin-side registries read manifests themselves,
  with `enabled?` only: `ConnectedAccounts::ProviderRegistry` (OAuth
  providers) and `PluginRuntime::DesiredServiceCollection` (supervised
  services). Plugins may use only the declared Host API, and health is "not
  promised" there. That is NY18.

---

## F67. A reordered app event was dropped as a duplicate — fixed

**Found by** DOC-44 Phase 5, frontend realtime synchronization
(`EventSequence.lean`).

**Property.** For every delivery order of up to four distinct events, with any
one of them delivered twice, every event is applied exactly once
(`applied_exactly_once`).

**Gap.** `AppEvents.broadcast` gives each user-channel event a per-user
`sequence`. The counter is incremented in the database, and the event is then
published by whichever process is broadcasting. Two processes can therefore
publish 11 before 10.

`trackAppEventSequence` (`app/frontend/lib/appEvents.ts`) classified every
sequence not above the highest seen as a duplicate. So a late 10 was dropped
entirely, together with its entity patch and its query invalidation
(`late_event_dropped`). The gap detected at 11 refreshed only 11's resource,
so 10's resource stayed stale until some unrelated refetch.

The existing test "ignores a duplicate or replayed event outright" encoded
this behaviour: it asserted that an unseen lower sequence is ignored.
ActionCable does not replay messages, and a reconnect resets sequence
tracking, so an unseen lower sequence can only be a late delivery.

**Fix.** The client remembers the highest sequence and every sequence seen in
a 256-wide window below it.

- Only a seen sequence is a duplicate.
- An unseen lower one is `late` and is applied like any other event.
- A sequence below the window is treated as a duplicate, because no reorder
  is that wide.

Older fields still cannot win: `upsertEntity` compares revisions on its own
(the new test "still lets the entity store's revision guard reject a late
event's older fields").

**Spec.** `appEvents.test.ts`:

- "applies a late, never-seen lower sequence instead of dropping it as a
  duplicate" (red before);
- "ignores a late sequence a second time once it has been applied";
- the true duplicate case is kept.

All 515 frontend lib tests pass. The worktree needed `npm ci` to run them.

**Remaining.** An event that never arrives still leaves its resource stale.
Its resource is unknown, and the gap refresh covers only the event after the
gap. This is the plan's "global sequence-gap issue", queued as NY19.

---

## F68. A shared chat never updated live for the person it was shared with — fixed

**Found by** DOC-44 Phase 5, "Job- and Chat-scoped events cannot affect another
resource or unauthorized user," and its converse (`ChatDelivery.lean`).

**Property.** On every broadcast, the chat subscribers reached are exactly
those authorized at that moment (`reaches_exactly_authorized`, checked over
every state of four users).

**Gap.** `ChatChannel` lets a user subscribe when the chat is in
`accessible_chat_sessions`: owner, participant, or `ChatShare` target. Each
subscription gets its own `(chat, user)` stream. But
`AppEvents.broadcast_chat_resource` published only to participants' streams.
A share target is by validation never a participant
(`ChatShare#target_is_not_participant`), so a person viewing a chat shared
with them subscribed successfully and then received no new message
(`viewer_missed`). `Chat.tsx` polls only while disconnected, so the open chat
stayed stale until a focus refetch.

**Checked and refuted along the way.** Marking a chat read runs
`find_or_create_by!` on a participant row. For a share viewer that would have
created a `member` row and lifted the chat's `read_only`. It cannot happen:
`Api::V1::App::BaseController#prevent_shared_chat_mutations` forbids every
non-GET on `/chats/:id` from a share viewer who is not a participant, which
covers `mark_read` and posting alike.

**Fix.** `broadcast_chat_resource` publishes to participants and to the
chat's user share targets, recomputed on each broadcast. So revoking a share,
or removing a participant, stops delivery to an already-open subscription.

**Spec.** `app_events_spec.rb` "also reaches users the chat is shared with, and
no one else" was red before. `chat_shares_spec.rb` and the channel specs still
pass.

**Remaining.** `JobChannel` streams one shared `job_resource:<id>` stream and
checks `Job.visible_to` only on subscribe. A user whose visibility of the Job
is revoked keeps receiving its Workflow, Step and Run patches while the tab
stays open. That is NY20.

---

## F69. A database hiccup switched disabled plugins back on — fixed (NY13)

**Found by** DOC-44 plugin host semantics (queued as NY13). Decision:
"We should not treat installed plugins as enabled. This is potentially
destructive. We need to retry until we have a straight answer."

**Property.** Outside an asset build, the enablement answer is exactly what
the first non-transient read within the retry budget says. That is the
records, or the declared defaults when the database or table does not exist.
Otherwise there is no answer. It is never "every installed plugin"
(`EnablementRead.never_enables_disabled_and_answers_when_readable`, checked
over every outcome sequence of three attempts and every combination of two
plugins' defaults and records).

**Gap.** Several call sites answered a database error with "every installed
plugin is enabled":

- `Syrus::PluginRegistry.providers_for`, `all_plugins`, `health` and
  `credential_types` caught any `ActiveRecord::ActiveRecordError`;
- `beta_mode_enabled?` answered `true`;
- the Installer answered "install everything".

So a lock-wait timeout or a dropped connection made a disabled plugin
callable for that call: an execution backend, an approval provider, a
repository content provider (`blip_enables_disabled`). The fallback existed
so that asset precompile and a first boot work without a database.

**Fix.** One read, `PluginRegistry.enablement_records`, decides every case:

- **No database or no table** (`NoDatabaseError`, or `plugin_records`
  missing, as for `db:create` or a fresh database before migration): the
  declared defaults, which are exactly what the records will say once
  created.
- **Asset build** (`SECRET_KEY_BASE_DUMMY`): every plugin. There is no
  instance and no database, and the build needs every plugin's assets.
- **Any other error:** retried three times with short backoff, then
  `EnablementUnavailable` is raised. The caller fails instead of guessing.
  `beta_mode_enabled?` raises the same way.

`Syrus::Installer.sync!` resolves the enabled set *before* disposing
anything. On `EnablementUnavailable` it keeps every installed effect and
leaves its fingerprint, so the next sync tries again.

A process whose database server is down at boot now fails boot and is
restarted until it can read enablement, instead of booting with guessed
plugins. `db:create` and the first `db:prepare` still boot, through the
missing-database case.

**Spec.**

- `plugin_registry_spec.rb` "when plugin enablement cannot be read":
  - defaults for a missing table and for a missing database;
  - raises after the retry budget, from `providers_for`, `all_plugins` and
    `health`;
  - a transient error is retried and answered from the records;
  - every plugin only for an asset build.
- The four specs that pinned the old fallback now state the decision.
- `installer_spec.rb` "keeps installed effects while plugin enablement
  cannot be read, then resyncs".

---

## F70. A user who lost access to a Job kept receiving its live updates — fixed (NY20)

**Found by** DOC-44 Phase 5 (F68's remaining case, queued as NY20). Decision:
prevent it.

**Property.** No Job event reaches a subscriber more than one recheck interval
after that subscriber lost access, and every event before that is delivered
(`ScopedDelivery.bounded_after_revocation`, checked over every revocation
tick, every message pattern on a ten-tick timeline, and intervals 1 to 3).

**Gap.** `JobChannel` authorized with `Job.visible_to` only on subscribe, then
streamed one `job_resource:<id>` stream shared by every subscriber. Removing a
repository membership, narrowing Job visibility, or losing the admin role did
not end open subscriptions. Until the tab reconnected, that user kept
receiving the Job's Workflow, Step and Run patches: state, timestamps, PR
title, summary and cost (`revoked_kept_receiving`).

**Fix.** Each delivery rechecks the same `Job.visible_to` the subscription
used, trusting a positive answer for `VISIBILITY_RECHECK_INTERVAL` (10 s), so
high-churn patches do not each cost a query. Once the check fails, the channel
stops its streams and transmits nothing more.

This differs from the recommendation recorded with NY20, which was to
disconnect on membership changes. Visibility depends on memberships, teams,
ownership, archiving, the admin role and plugin-supplied restrictions, so a
hook-based disconnect would leave a hole for any input it missed. Rechecking
the one predicate the subscription itself uses covers all of them.

**Spec.** `job_channel_spec.rb` "delivery after access changes":

- a visible subscriber receives;
- after the membership is removed and the interval passes, nothing is
  transmitted and the streams are stopped (red before: the method did not
  exist and every message went out);
- a second delivery inside the interval does not query again.

---

## F71. A genuinely lost app event left its resource stale — fixed (NY19)

**Found by** DOC-44 Phase 5, the plan's "global sequence-gap issue" (F67's
remaining case, queued as NY19). Decision: wait about 2 s for late
deliveries, then sweep.

**Property.** A continuity sweep runs exactly when some sequence in a gap is
still missing when the grace timer fires
(`GapRecovery.sweeps_iff_still_missing`). This is checked over every
assignment of up to four events to an arrival tick or "lost". So every event
lost for good is recovered, and a gap that closes in time costs no sweep.
The model's "still missing" is computed from the delivered set rather than
the client's bookkeeping, so it is close to a restatement; the vitest cases
below are the behavioural evidence.

**Gap.** On a gap (10, then 12), the client refreshed only event 12's
queries. Event 11's resource is unknown, so if 11 never arrived, that
resource stayed stale until an unrelated reconnect, focus refetch or later
event (`lost_left_stale`).

**Fix.** In `trackAppEventSequence` (`app/frontend/lib/appEvents.ts`), a gap
records the skipped sequences in `missing`, bounded by the 256-wide window,
and starts one timer of `APP_EVENT_GAP_GRACE_MS` (2 s). A late delivery
removes its sequence (F67). When the timer fires with anything still missing,
the client runs `recoverAppEventContinuity`, the same sweep a reconnect does,
which already defers for hidden tabs. A reconnect cancels the timer, because
its own recovery sweeps anyway. The existing `revision_gap_recoveries` metric
still counts gaps; no metric was added, since client metric names are a
closed set on both sides.

**Spec.** `appEvents.test.ts` "genuinely lost events":

- a sweep after the grace period with a sequence still missing, and none
  before it (red before: no sweep ever ran);
- no sweep when the late sequence arrives in time;
- no sweep after a reconnect.

All 518 frontend lib tests pass, and lint and tsc are clean.

---

## F72. Plugin-side registries kept unhealthy contributors live — fixed (NY18)

**Found by** the F66 audit of direct `manifest.provides` readers (queued as
NY18). Decision: B, add a health-aware owner-aware lookup.

**Property.** The single callable gate (`EffectHealth.lean`: enabled and
healthy, for the host and each contributor) now also governs the two
plugin-side registries that need to know which plugin contributed each entry.

**Gap.** `ConnectedAccounts::ProviderRegistry` (OAuth provider declarations)
and `PluginRuntime::DesiredServiceCollection` (supervised and privileged
services) each read manifests themselves with `enabled?` alone. A degraded or
failed contributor's OAuth provider stayed offered, and its service kept
running. The Host API gave plugins no other way to learn the owner of a
provider.

**Fix.** `Syrus::PluginRegistry.providers_with_owner_for(point)` returns
`[plugin_name, provider]` pairs for a plugin-hosted point, from the same
enabled-and-healthy set as `providers_for`, and `hosted_providers_for` is now
built on it. It is on the declared Host API
(`lib/syrus/host/public_apis.rb`). Both registries use it. Plugin Runtime's
first-party allowlist now checks the owning plugin's name
(`eligible_plugin?`).

**Spec.**

- `plugin_registry_spec.rb` `.providers_with_owner_for`: owners are paired,
  and a degraded contributor or an unhealthy host yields nothing.
- `provider_registry_spec.rb` "withholds a valid provider whose contributing
  plugin is unhealthy" (red before).
- The connected-accounts spec now registers `credential_store`. It had relied
  on a host degraded by its own missing hard dependency still contributing,
  which is the bug itself.
- The plugin_runtime specs stub the new lookup instead of `all_plugins`
  doubles. Enablement and health are the core lookup's responsibility.

---

## F73. A worker without a plugin failed that plugin's step on first claim — fixed (NY17)

**Found by** the plugin-set admission audit (M17, queued as NY17). Decision:
prevent it.

**Property.** A Step of a plugin's kind fails as unknown only after the
hand-back budget is spent, and a capable worker that claims it within the
budget runs it (`UnknownKindHandback.fails_only_after_budget_and_capable_claim_runs`,
checked over every claim sequence of up to six claims).

**Gap.** Routing sends a Run to a queue that every worker of that OS
consumes. So during a fleet plugin rollout, or for a fleet installation
limited to some roles, a worker without the plugin could claim the Run.
`Steps.handler_for` then raised and the Step failed terminally
(`failed_on_first_wrong_worker`). Failing it also raised a second time,
because `Step::Kind.remediation_for` looked the unknown kind up during the
failure cascade.

**Fix.**

- **First claim:** `RunJob#hand_back_unknown_step_kind?`, checked before the
  Run is claimed. A worker that does not provide the Step's kind hands the
  Run back after 30 s, counting `unknown_kind_handbacks` on the Step. After 20
  hand-backs (about 10 minutes with no capable claim) it lets the Step fail as
  unknown.
- **Inline successor:** a successor this process cannot run goes back to the
  queue through the ordinary hand-back.
- **Failure path:** `Step::Kind.remediation_for` answers `nil`, meaning no
  step-kind opinion, for an unknown kind, like its `label_for` and
  `review_gate_for` siblings, so the Step can fail cleanly. This is also a
  first part of NY14.

**Not done.** Routing by plugin, so that an incapable worker never claims the
Run at all, would need per-plugin queues. The capability resolver routes by
queue name, and every worker of an OS shares the queue. The hand-back is
what makes the step survive in the meantime.

**Spec.** `run_job_unknown_step_kind_spec.rb`:

- an unknown kind is handed back with the Run still queued (red before: it
  raised);
- with the budget spent, it fails instead of being handed back again.

The job, step, dispatcher and remediation specs pass (854 examples).

---

## F74. A disabled or unhealthy plugin's in-flight work could not be cancelled — fixed (NY14)

**Found by** F61's remaining case (queued as NY14). Decision: A, keep kind
metadata resolvable for existing rows, and let only new work require a
healthy owner.

**Property.** An existing row always gets a definition. A launch gets one
exactly when the kind is built-in or its owner is enabled and healthy, and
the neutral `Unavailable` definition is never what a launch receives
(`ExistingKindDefinition.existing_always_answers`,
`launch_needs_healthy_owner`, `unavailable_never_launches`).

**Gap.** F61 kept rows of a withdrawn kind saveable. But
`Workflow#work_definition` still resolved through the live registry, and the
cancel cascade asks it questions (`infrastructure_workflow?` in
`Workflows::JobLifecyclePropagation`). So `WorkUnits::WorkflowCancellation`
raised `WorkDefinitions::UnknownKind` for an in-flight Workflow whose plugin
was disabled or unhealthy (`cancel_raised`). That work could be neither
finished nor cancelled.

**Fix.**

- `WorkDefinitions.for_existing(kind)` answers like `.for` while the kind is
  registered. Otherwise it returns the definition from the installed plugin's
  own `workflow_kinds` provider, whatever the plugin's state. If the plugin is
  uninstalled or failed to load, it returns `WorkDefinitions::Unavailable`.
- `Unavailable` keeps Base's conservative defaults: operator-only retries,
  not infrastructure. Its plugin marker is never provided, so it is never in
  the registry, and `.for`, which every launch path uses, never returns it.
- `Workflow#work_definition` uses `for_existing`.
- F73 made `Step::Kind.remediation_for` neutral for an unknown kind, so the
  Step side of the cascade does not raise either.

**Spec.**

- `plugin_kind_persistence_spec.rb` "can still cancel the in-flight workflow,
  its steps and runs" (red before: `UnknownKind`). This file moved into
  `plugins/agent_insights/spec/models/`, because core specs must not depend
  on a bundled plugin.
- `work_definitions/for_existing_spec.rb`: `Unavailable` for an uninstalled
  kind, never registered and never returned by `.for`, and identical to
  `.for` for a registered kind.
- `agent_insights/work_definition_for_existing_spec.rb`: a disabled plugin's
  own definition is still resolved for existing rows.

---

## F75. The CLI's API client could send the user's token to another host — fixed

**Found by** DOC-44 Phase 6, Syrus CLI: "API requests attach bearer tokens
only to the selected instance origin," and "Plugin CLI paths cannot use the
central client to send credentials to an absolute or scheme-relative foreign
URL."

**Gap.** `api.Client.newRequest` (`cli/pkg/api/client.go`) resolved the given
path against the instance URL with `ResolveReference`, then always set
`Authorization: Bearer <token>`. An absolute path (`https://other.host/x`) or
a scheme-relative one (`//other.host/x`) resolves to that other host. Because
`Client.Do` is exported precisely so that third-party plugin CLI modules can
call it, a plugin, or any path assembled from server-supplied data, could
deliver the user's Syrus token to an arbitrary host. The test saw `Bearer
secret-token` arrive at the foreign server for both forms.

Already safe: Go's HTTP client drops `Authorization` on a redirect to a
different domain. The other places that set the header (`plugin_commands.go`,
`plugin_new.go`, `local.go`) append fixed paths to the saved instance URL.

**Fix.** `newRequest` refuses a path that names its own scheme or host, and
checks that the resolved endpoint keeps the instance's scheme and host, before
any request is built.

**Spec.** `client_test.go` "TestRequestsNeverCarryTheTokenToAnotherOrigin":
both forms are refused, the foreign host is never contacted, and an instance
path still works (red before: two foreign hits carrying the token). All CLI
packages pass and `go vet` is clean. This is adapter behaviour, so it is
established by the Go test rather than a Lean model, as the plan assigns
CLI adapters.

---

## F76. Saving credentials wrote the token through a symlink and into a loose file — fixed

**Found by** DOC-44 Phase 6, Syrus CLI: "The credentials file only ever holds
the token under mode 0600 at the configured path itself."

**Gap.** Both writers of the shared `~/.syrus/credentials` file wrote the path
directly. In the CLI this is `config.SaveCredentials`, which used `os.WriteFile`
and then `os.Chmod`. In the desktop app it is `writeCredentialsFile`, which used
`fs.writeFile` with `mode` and then `chmod`. Writing the path directly causes
two problems:

- **A symlink at the path** sent the token into the link's target, under that
  target's permissions. The tests saw `secret-token` land in an unrelated
  0644 file.
- **A pre-existing file with loose permissions** held the new token while its
  mode was still loose, until the chmod ran. Both `WriteFile` and Node's
  `writeFile` apply `mode` only when they create the file.

A crash in the middle of the write could also leave a truncated credentials
file.

**Fix.** Both writers now create a fresh 0600 file beside the path, sync it,
and rename it over the path. The rename replaces the symlink itself and is
atomic. The temporary file is removed on every exit path.

**Spec.**

- `credentials_test.go` "TestSaveCredentialsNeverWritesThroughASymlink".
- `desktop/src/credentialsStore.test.ts`: the symlink case, plus the loose
  pre-existing file, which must be replaced by a new inode at 0600 with no
  temp-file leftovers.

Both were red before the fix. All CLI packages pass.

---

## F77. A profile name could move the credentials file out of ~/.syrus — fixed

**Found by** DOC-44 Phase 6, Syrus CLI profile precedence: "Every profile
resolves to a credentials file directly inside `~/.syrus`."

**Gap.** `config.Profile` resolves the profile from `--profile`, then
`SYRUS_PROFILE`, then argv[0]. It keeps any unrecognized value verbatim.
`DefaultCredentialsPath` then splices that value into the filename
`credentials.<profile>` and joins it under `~/.syrus`. As a result:

- `--profile x/../../.ssh/authorized_keys` resolved to `~/.ssh/authorized_keys`.
- A later `syrus login` would replace that file with `url=`/`token=` lines.
  After F76 the write is a rename, so the file would be replaced outright.

A `SYRUS_PROFILE` inherited from a hostile environment reaches the same path.
The desktop app is not affected, because it chooses between two fixed
filenames.

**Fix.** `DefaultCredentialsPath` refuses any profile that is not a plain name
of lowercase letters, digits, `-` and `_`. Values are already lowercased by
normalization.

`go vet` flagged a pre-existing possible context leak in `cmd/local.go`: a
`WithCancel` call ran before an early return on a JSON-marshal error. The
context is now created after that return, and vet is clean.

**Spec.** `profile_test.go`
"TestDefaultCredentialsPathRefusesProfilesThatLeaveTheSyrusDirectory" covers
separators of both kinds, `..`, and spaces, and checks that valid names still
resolve. It was red before: the first case resolved to
`~/.ssh/authorized_keys`. All CLI packages pass, and vet is clean.

---

## F78. A reported Syrus version became Ruby in a scaffolded gemspec — fixed

**Found by** DOC-44 Phase 6, CLI plugins and scaffolding: "Scaffolded
projects contain only template text and validated names; no input becomes
code."

**Gap.** `syrus plugin new` takes the oldest supported Syrus version from
`--syrus-version`. By default it takes it from the connected instance's
`/api/v1/app/bootstrap` (`connectedInstanceVersion`), and it splices that
value into `spec.metadata["requires_syrus"] = ">= {{SYRUS_VERSION}}"`.

- **Ruby injection.** Bundler evaluates a gemspec as Ruby. A reported version
  such as `1.0"; system("touch pwned"); "` produced
  `">= 1.0"; system("touch pwned"); ""`, which runs on the developer's machine
  at the next `bundle` or `syrus plugin test`.
- **Docker image tags.** The same reported value also picks the Docker image
  tag for `plugin test` and `plugin dev`. It is passed as a single argv
  element, so it cannot inject flags, but it was otherwise unchecked.

The plugin name was already validated by `pluginNamePattern`. The destination
must be empty or absent.

**Fix.**

- `instanceVersionFromReported` keeps a reported version only when it is a
  plain release version: digits and dot-separated parts, with an optional
  pre-release and build part, at most 64 characters. Anything else falls back
  to the CLI's release version, as development describes already did.
- `generatePluginScaffold` refuses any version that is not plain. This also
  catches a dev-build fallback of `latest`, which used to produce the invalid
  requirement `>= latest`.

**Spec.** `plugin_new_test.go` has two tests:

- "TestGeneratePluginScaffoldRefusesAVersionThatIsNotAPlainVersion" (red
  before: the gemspec contained `system("touch pwned")`);
- "TestInstanceVersionIgnoresAReportedVersionThatIsNotAPlainVersion".

All CLI packages pass and vet is clean.

---

## F79. uninstall.sh and the desktop app classified image tags differently — fixed; channel isolation proved

**Found by** DOC-44 Phase 7, desktop backend lifecycle: "Stable and test
project names, ports, containers, images, and volumes are disjoint", and
"Every destructive target derives from a validated channel-specific
manifest."

**Gap.** Both channels pull from the same `syrus-backend` repository, so an
image's channel is read from its tag. There are two copies of that rule:

- The desktop's `tagChannel` (`desktop/electron/channel.ts`) says test means
  `test-<x>`, or a tag *ending* in `-test.<digits>`.
- `uninstall.sh`'s image sweep used the glob `test-*|*-test.[0-9]*`, which
  also matches `-test.<digit>` *anywhere* in the tag.

For tags such as `0.1.2-test.4-hotfix` or `0.1.2-test.4.1`, the app says
stable and the script says test. So a test uninstall retired them, and a
stable uninstall left them behind. `spec/desktop/channels_spec.rb` only
checked that the glob text was present. The new example ran the script and
saw the test channel remove both tags.

The impact is bounded: `rmi` without `-f` refuses an image a container still
uses. But the disagreement is exactly the cross-channel deletion the property
forbids.

**Fix.** The script uses tagChannel's exact rule:
`[[ $tag == test-* || $tag =~ -test\.[0-9]+$ ]]`. This works in macOS's bash
3.2.

**Proved.** `ChannelIsolation.lean` encodes the per-channel resource table
that `stackIdentity` and `uninstall.sh` share, and the targets of `wipe` and
`uninstall` (with and without `--keep-data`). It proves four things:

- the two channels' resources are disjoint;
- every destructive target lies in its own channel's set;
- a stable `wipe` removes nothing;
- `--keep-data` removes no data.

It rests on three audited premises:

- `compose -p` overrides the compose file's `name: syrus`, and no volume has a
  fixed `name:`;
- plugin-runtime resources are selected by the project label;
- `~/.syrus` itself is only `rmdir`'d when empty, and a test uninstall skips
  the stable-only skill.

**Spec.**

- `spec/desktop/uninstall_spec.rb` "retires exactly the tags the desktop
  classifies as this channel's" runs the real script over the same tags on
  both channels. It is CI-only; run it locally with `RUN_CI_ONLY_SPECS=true`.
  Red before.
- `desktop/src/channel.test.ts` pins the same tags on the app side.

---

## F80. A watchdog probe in flight could override a deliberate stop — fixed

**Found by** DOC-44 Phase 7, desktop backend lifecycle: "Watchdog recovery
does not override a deliberate stop."

**Gap.** The watchdog reports only health transitions, measured against
`lastHealthy`. `stopBackend` sets `lastHealthy := false`, so the "stopped"
page is not replaced by an outage. But a tick checked `backendBusy()` only
when it began, and then awaited `backendHealthy()`. The race ran like this:

1. A tick's probe starts while the stack is up.
2. The user stops the backend, and the stop finishes while the probe is still
   outstanding.
3. The stale probe answers "healthy", which flips `lastHealthy` back to true
   and reports healthy.
4. The next tick reports the deliberately stopped stack as `containers-down`.

The vitest reproduction saw exactly `[true, null]` followed by
`[false, "containers-down"]`.

The update path was audited and holds:

- the deadline settles `false` once, and a later `close` cannot resolve it
  again;
- `busy` clears in `finally`;
- `ChildTerminationController` keeps the backend busy until the installer
  really exits or is SIGKILLed;
- old images are removed only after `ok && backendHealthy()`.

**Fix.** `start`, `stop` and `update` each bump a lifecycle generation when
they take the stack. A tick drops its result if the generation changed, or a
lifecycle action is running, at either await point. It sets `lastHealthy`
only when it reports.

**Proved.** `WatchdogStop.lean` checks every interleaving of up to seven tick
begin/end, stop, start, crash and recover events:

- after a stop with no later start or recover, nothing is reported;
- the old unguarded tick violates this, on tick-begin, stop, tick-end;
- a crash followed by a full tick is still reported.

**Spec.** `desktop/src/backendWatchdog.test.ts` drives the real module with
fake timers and stubbed Docker:

- "never lets a probe that started before a deliberate stop override it" (red
  before);
- "still reports a stack that goes down and comes back on its own".

**Also fixed.** `spec/desktop/desktop_settings_spec.rb` still looked for the
`mode: 0o600` text that F76 replaced, and F76 had not run the desktop specs.
It now checks for the temporary file and the rename. All 389 desktop specs
(run with `RUN_CI_ONLY_SPECS=true`) and all 299 desktop vitest tests pass.

---

## F81. The desktop cable delivered pings and unconfirmed or rejected frames — fixed

**Found by** DOC-44 Phase 7, desktop ActionCable and notifications:
"Subscription rejection delivers no messages", "Stale socket callbacks are
ignored", "Confirmation resets backoff", and "Error and close callbacks
schedule at most one reconnect".

**Gap.** `AppUserCableClient` forwarded every frame that had a `message` key
to `onMessage`. That handler broadcasts the payload to every window and to the
native notification dispatcher. Three kinds of frame got through that should
not have:

- ActionCable pings, `{type: "ping", message: <timestamp>}`. The server sends
  one every few seconds, so each window received a stream of numbers.
- Broadcasts that arrived before `confirm_subscription`.
- Broadcasts on a socket after `reject_subscription`, and frames for any other
  identifier.

The handlers currently ignore non-object payloads and unknown types, so the
harm was noise rather than a false notification. But the property is a
delivery contract, and the next consumer would have inherited it.

**Already sound.**

- Every callback checks the socket's generation, and `start`/`stop` bump it.
- `finish` is idempotent, so each socket schedules at most one reconnect.
- Backoff doubles up to a cap, and resets on confirmation.
- An `unauthorized` disconnect marks the token suspect and stops reconnecting.
- A credential change starts a new generation, so the old token is never
  reused.

**Fix.** Each socket tracks whether its own subscription is confirmed.
`onMessage` receives a frame only if it is untyped (a broadcast, not a
protocol frame), carries this channel's identifier, and arrives while the
subscription is confirmed. A rejection clears the confirmed state.

**Proved.** `CableDelivery.lean` checks every sequence of up to six frames on
one socket:

- each delivered frame is an own-channel broadcast that follows a confirmation
  with no rejection after it;
- the old behaviour violates this;
- a confirmed broadcast is delivered.

**Spec.** `desktop/src/appUserCable.test.ts` has two new tests, both red
before:

- "delivers only this channel's broadcasts, and only once the subscription is
  confirmed";
- "delivers nothing on a socket whose subscription was rejected".

All 301 desktop vitest tests and 389 desktop specs pass.

---

## F82. A link or file dropped on a privileged desktop window ran with the credential bridge — fixed

**Found by** DOC-44 Phase 7, Electron security boundary: "untrusted renderer
content cannot invoke filesystem, credential, backend-control, or process
IPC".

**Gap.** The tray popover, Preferences and onboarding windows load the bundled
renderer with `preload.cjs`. Its handlers include `get-credentials` (returns
the saved API token), `save-credentials`, `checkout-job` and the installer
controls, and none of them check the sender. The windows had no
`will-navigate`, `will-redirect` or `setWindowOpenHandler` guard, no global
`web-contents-created` guard existed, and the renderer does not cancel drops.
Electron navigates a window to a link or file dropped onto it by default. So
dropping a link or a downloaded HTML file onto Preferences loaded foreign
content with `window.syrus.getCredentials()` available.

The web-app window was already sound, in three layers:

- navigation, redirects and popups go through `decideWindowOpen`;
- the window is sandboxed;
- every handler on its bridge (`shell:*`, `annotation:*`, `recorderHud:*`,
  `dictation:*`) checks the sender is the web-app window's top frame on the
  instance origin.

`open-external` allows only http(s). App auto-update is armed only for stable
packaged builds. "Restart to update" refuses while a backend update is running,
and a plain Quit kills the installer tree instead of orphaning it.

**Fix.** `windows/privilegedWindowGuard.ts` `lockPrivilegedWindow` refuses
every content-started navigation, redirect and popup. The main process's own
`loadFile` and `loadURL` never fire `will-navigate`. The popover, Preferences
and onboarding windows install the guard.

**Proved.** `PrivilegedWindows.lean` checks every sequence of up to four
content-started navigations:

- a privileged window only ever shows the local renderer;
- the web-app window only ever shows the server origin;
- the unguarded window reaches `file:` content.

**Spec.**

- `desktop/src/privilegedWindowGuard.test.ts` covers the guard.
- `spec/desktop/privileged_window_guard_spec.rb` finds every `BrowserWindow`
  given the privileged preload and requires it to be locked. It was red with
  the wiring removed ("main.ts creates mainWindow with the privileged preload
  but never locks it").

All 302 desktop vitest tests and 391 desktop specs pass. `npm run typecheck`
for the desktop is clean; its dependencies are now installed in the worktree.
This typecheck also covers F76, F80 and F81.

---

## F83. Onboarding: a cancel during lock acquisition still spawned the installer, and a reused PID kept a stale lock forever — fixed

**Found by** DOC-44 Phase 7, installer and onboarding:

- "Only one installer owns the install lock";
- "Cancellation eventually terminates the complete child-process tree";
- "Every terminal path releases the lock";
- "Interrupted installation remains diagnosable and recoverable".

**Gap 1: cancelling while the lock is acquired.**
`OnboardingDriver.performStartInstall` awaits the state directory, the backend
manifest and the install lock, then spawns the installer. Cancellation was
checked only after the manifest. If a cancel arrived while
`acquireInstallLock` was in flight:

- `cancelInstall` reset the wizard to Welcome;
- the start then resumed, set `local.installing` and spawned an installer;
- nothing killed that installer, because the cancel had already been handled.

The vitest reproduction holds the lock's `open` and cancels in that window. It
saw the spawn.

**Gap 2: a stale lock behind a reused PID.** A stale lock was broken only when
its PID was dead. An install interrupted by a reboot, which is the case
reboot-resume exists for, leaves the installer's PID in `install.pid`. After a
reboot, PIDs are reused. If any process now runs under that PID, every install
was refused as "A Syrus installation is already running" until the file was
deleted by hand.

**Already sound.**

- The lock is created with `wx`, so only one creator wins.
- While the installer runs, the lock holds the installer's own PID.
- Release only removes a lock that holds our PID, unless the release is
  forced.
- A cancel after the spawn kills the process group and escalates to SIGKILL.
- `handleExit` returns to Welcome on a cancelled run, even if the exit code is
  0.
- The backend config is saved only on exit 0, which comes after the
  installer's own health gate.
- Quitting waits for the installer tree to close (F82 audit).

**Fix.**

- The start re-checks cancellation after acquiring the lock. If a cancel
  arrived, it releases the lock and stops.
- A lock whose modification time is before the current boot (`now - uptime`,
  with a minute of slack) is treated as stale, whatever its PID.

**Model.** `InstallCancel.lean` is a table of the start's code paths, one row
per point where a cancel can land:

- a cancel before the spawn never spawns and leaves no lock;
- a cancel after the spawn kills the installer;
- every cancelled path ends at Welcome;
- the old behaviour spawned on a cancel during lock acquisition.

**Spec.** `desktop/src/installerDriverCancel.test.ts` drives the real driver
with a held lock `open` and a fake `spawn`. Both tests were red before:

- "never spawns an installer after a cancel that lands while the lock is being
  acquired";
- "breaks a lock written before the last boot even when its PID is in use".

All 304 desktop vitest tests and 391 desktop specs pass, and the desktop
typecheck is clean.

---

## F84. A stale onboarding precheck overrode navigation and could start an install — fixed

**Found by** DOC-44 Phase 7, installer and onboarding: "Stale probe results
cannot race navigation and change wizard state", and "Remote mode cannot
mutate the local backend".

**Gap.** `OnboardingDriver.precheck` awaits up to six probes in turn:

1. read the `.env`;
2. check Syrus's health on the port;
3. fingerprint whatever answers;
4. find the Docker binary;
5. check the daemon, which allows up to 10 s;
6. look for the data volume and probe the port.

Then it sets the next screen, or calls `startInstall()` directly. It never
re-checked that it was still current. "Run Setup Again…" (`reset`), or any
other navigation that landed while it probed, was overridden by the stale
result, which could go on to start an install. The vitest reproduction holds
the daemon probe, resets the wizard, then answers. The stale precheck spawned
the installer.

`connectRemote` was already sound: it re-checks the phase and URL after its
probe. So was `probeInstance`, which is stateless. Remote mode cannot touch the
local backend: start, stop, update and `ensureRunning` all return early unless
the backend mode is `local`. The test-only wipe is gated on the channel.

**Fix.** The precheck captures the navigation generation (`pollGeneration`).
Every navigation bumps it through `stopPolling`. After each probe the precheck
stops if the generation moved on or the phase is no longer `local.precheck`.

**Spec.** `desktop/src/installerDriverPrecheck.test.ts` "drops its result when
the wizard was reset while it probed" was red before (an installer was
spawned). No Lean model: an encoding of "check after every await" would only
restate the fix, so the adapter test is the evidence. This follows the
pattern of the existing generation proofs, `WatchdogStop` and the cable
generations.

All 305 desktop vitest tests and 391 desktop specs pass, and the desktop
typecheck is clean.

---

## F85. The tray badge never resynced after a cable outage — fixed; credential and notification semantics audited

**Found by** DOC-44 Phase 7:

- desktop credentials: "Failed validation cannot replace valid stored
  credentials";
- desktop ActionCable and notifications: "Notification delivery semantics are
  explicitly at-least-once or exactly-once", "If duplicates are permitted,
  unread-count behavior eventually reconciles to an authoritative count", and
  "Main-process and renderer notification paths do not jointly create
  uncontrolled duplicates".

**Semantics, as implemented.**

- *Delivery is at most once.* `NotificationService` broadcasts once, after the
  notification row commits, and ActionCable keeps no replay.
- *The count is authoritative per broadcast.* The broadcast carries the
  server's `unread_count`, and `handleNotificationCreated` sets the badge from
  it. Only a payload without a count falls back to `+1`.
- *No main/renderer duplication.* The main process shows a native
  notification only when the web-app window is not live, visible and
  unminimised. Otherwise the web app shows it, so the two paths never both
  fire for one event.

**Gap.** Because delivery is at most once, a broadcast missed while the cable
was down is gone. The badge resynced only on bootstrap (startup and
credentials save), when the tray popover opened, or with the next
notification. After an outage, a missed notification, or one read on another
device, left the badge wrong indefinitely if none of those happened.

**Fix.** `AppUserCableClient` reports every confirmed subscription through
`onSubscribed`, on the first connect and every reconnect. Main resyncs the
badge from `/notifications` there. Errors are swallowed; the badge is cosmetic.

**Credentials hold.** `saveCredentials` validates with the server before
`writeCredentialsFile`, so a failed validation throws before anything touches
the stored file. `CredentialMutationCoordinator` serialises operations and
lets a newer one supersede an older one. The newest operation always runs
last, so it is the final mutation on disk.

**Spec.** `desktop/src/appUserCable.test.ts` "reports every confirmed
subscription so the unread count can resync" was red before (0 calls). All
306 desktop vitest tests and 391 desktop specs pass, and the desktop typecheck
is clean.

---

## F86. "Reset Test Setup" could wipe the stack under a running start or update — fixed

**Found by** DOC-44 Phase 7, backend lifecycle and data safety: "Start, stop,
update, reset, and uninstall are mutually exclusive where required", and
"Missing data is distinguished from temporarily stopped containers".

**Gap.** `start`, `stop` and `update` are mutually exclusive. Each checks
`backendBusy()` and sets it with no await in between. The test-channel wipe
was not part of this:

- `confirmAndResetTestSetup` checked `backendBusy()` *before* its confirmation
  dialog. That dialog waits on the user indefinitely, and a backend update can
  be confirmed from its own dialog meanwhile.
- `wipeBackendStack` never took the lifecycle itself. A start or update
  confirmed while the reset dialog was open ran under `compose down -v`, and
  one begun during the wipe recreated the stack it was deleting.

Uninstall quits the app before its script runs (`uninstall.sh`, detached), so
it cannot overlap.

**Fix.**

- `wipeBackendStack` refuses while any lifecycle action is running, and is a
  lifecycle action itself: it bumps the F80 generation, holds `busy`, and
  clears it in `finally`. The work moved to `wipeStack`.
- `confirmAndResetTestSetup` re-checks after the dialog, so the usual case
  refuses before supervision is stopped.

**Missing data vs stopped holds.** The watchdog diagnoses `daemon-down`,
`data-gone` (the data volume is absent) and `containers-down` separately. A
deliberate stop shows the "stopped" page and is not reported as an outage
(F80).

**Spec.** `desktop/src/backendWatchdog.test.ts` "refuses while another
lifecycle action is running, and holds the lifecycle while it wipes" was red
before: the wipe resolved during a start. Two text specs were updated for the
`wipeStack` split. No Lean model: exclusion here is a check-and-set with no
await between, which a model would only restate. All 307 desktop vitest tests
and 391 desktop specs pass, and the typecheck is clean.

---

## F87. A CI repair that gave up closed a Job with an open PR as "no changes" — fixed

**Found by** DOC-44 job state, coverage item `feedback-does-not-regress-job`:
"Feedback and repair Workflows on an existing Job never regress its state."

**Gap.** Here is how a CI repair on an implemented Job reached the closure:

1. An approval-blocking follow-up (`ci_failure`, `pr_comment`, …) lifts the
   implemented Job to `running` when it starts.
2. `analyze_and_fix` raises `NoChangesProduced` when the agent's step made no
   change.
3. `JobLifecyclePropagation.fail!` diverts such a failure to
   `CiFailureNotReproduced` only when every grader in the Workflow passed or
   was inconclusive.
4. Otherwise it fell through to the generic rule, which closes the Job with
   reason `no_changes`.

So a CI repair whose agent gave up without a diff after a grader had already
reproduced the failure closed a Job that still had an open, unmerged PR. The
repair loop's later iterations are exactly this case. The spec saw `closed` /
`no_changes`. Two things made this worse:

- the PR's work was abandoned;
- `JobDependency::SatisfactionModes::Landed` treats a `no_changes` closure as
  landed (`landed.rb:16`), so dependents went ahead as if it had merged.

**Production** (read-only). The four recent `ci_failure` runs that failed with
`NoChangesProduced` all belong to Jobs that later closed as `pr_merged`. They
took the diversion branch, so the gap is reachable but not yet observed.

**Fix.** The `no_changes` closure applies only to a Job without a PR (no
`pr_number`, `external_pr_number` or `fork_review_pr_number`). That is its
meaning: an attempt that produced nothing. On a Job with a PR, the failure
follows the ordinary path to `failed`, where it is visible and retryable.

**Not changed.** `cancel!` of a follow-up that lifted the Job moves the Job to
`failed`, which keeps the PR and stays retryable. Existing specs pin this
intentionally ("still fails the Job when its only Workflow is cancelled").

**Proved.** `FollowUpFailure.lean` encodes `fail!` branch for branch, over
every Job state, PR or not, failure kind, CI diversion and lifecycle
ownership:

- a Job with a PR is never closed by a failed Workflow;
- it never returns to a pre-PR state;
- a Job without a PR whose attempt produced nothing is still closed as
  `no_changes`;
- the old rule closes a running Job with a PR.

**Spec.** `job_lifecycle_propagation_spec.rb` "fails, rather than closes, a Job
with a PR when a repair gives up after a reproduced failure" was red before:
it got `closed` / `no_changes`.

Also run and green:

- the propagation specs;
- the workflow, job, run_job, poll_pull_request, job_closure and
  stack_rebase_coordinator specs, with `spec/services/workflows` (370
  examples);
- the `ci_failure_repair`, `pr_review_feedback_repair` and
  `superseded_ci_repair_base_resolves` simulations.

---

## F88. Coding and local-mode handoffs could leave a Job running with nothing working on it — fixed

**Found by** DOC-44 job state, coverage item `job-running-without-work`: "A
Job is running or landing but no Workflow is working on it" must be
unreachable.

**Shape.** `JobLifecyclePropagation.lifts_job_on_start?` lifts the Job to
`running` for every kind except landing and infrastructure ones. Generic
`fail!` skips kinds that own their Job lifecycle, and generic `cancel!` also
skips the two handoff kinds. So for a lifecycle-owning kind that lifts the
Job, its own `after_fail` and `after_cancel` are the only things that can
settle the Job.

Enumerating the registry, three such kinds lift the Job:

- `coding_handoff`;
- `local_mode_handoff`;
- `external_pr_ingest`, which settles failure in `after_fail` and goes through
  generic `cancel!`.

**Gaps.**

1. `CodingHandoff.after_fail` began `return unless
   Feature.coding_mode_enabled?`, yet its own comment says generic
   propagation was suppressed. So a handoff that failed after Coding Mode was
   switched off left its Job `running`. An existing spec pinned this ("is a
   no-op … expect(job).to be_running").
2. Neither handoff defined `after_cancel`. The generic skip has been there
   since the propagation was first written, apparently copied from the
   failure-owner list. So any cancellation that did not close the Job
   stranded it in `running`.

**Fix.**

- `CodingHandoff.after_fail` settles the Job on every failure. Only the chat
  report depends on Coding Mode.
- Both handoffs gain `after_cancel` through `Workflows::HandoffCancellation`.
  It fails a Job left `running`, unless the cancellation was a supersession,
  and the local-mode variant also clears the chat link. This mirrors generic
  `cancel!`.
- The pinned no-op spec now asserts that the chat gets no report and the Job
  fails.

**Proved.** `RunningHasWork.lean` covers each category of kind that lifts the
Job, every terminal outcome, and Coding Mode on or off:

- once the Workflow ends, the Job is not `running`, except after a
  supersession, when newer work owns it;
- the old hooks strand it in all three cases.

**Specs.**

- `coding_handoff_spec.rb` "terminal outcomes always settle a running Job":
  red before on flag-off failure and on cancel.
- `local_mode_handoff_spec.rb` ".after_cancel": red before.
- `spec/architecture/lifecycle_owning_kinds_settle_job_spec.rb`: every
  lifecycle-owning kind that lifts its Job must define its own hooks. It was
  red with the hooks removed ("inherits the no-op after_cancel").

The `spec/services/workflows`, pending-action, workflow and job specs pass
(513 examples).

---

## F89. The drift classifier reported every rebase on an implemented Job — fixed; Lead L4 closed

**Found by** DOC-44 job state, coverage item
`job-state-vs-active-workflow-kind`, while working Lead L4.

**Gap.** `JobLifecyclePropagation.lifts_job_on_start?` deliberately leaves an
*implemented* Job implemented when a non-approval-blocking follow-up starts
(rebase, stack rebase, manual reviews, visual diff). But
`classify_job_workflow_drift` reported any active Workflow on an implemented
Job as `job_workflow_state_drift`, a warning that sends the operator to
"operator_review_state_transition". So every ordinary rebase on an
implemented Job read as drift while it ran.

**Fix.** The classifier skips an implemented Job whose active Workflows are
all non-approval-blocking. An approval-blocking Workflow on an implemented
Job, which start propagation would have lifted, is still reported.

**Proved.** `LegalJobWorkflowPairs.lean` encodes start propagation and the
classifier over every launch state and kind category:

- no pair that start propagation produces is reported as drift;
- an approval-blocking Workflow on an implemented Job still is;
- the old classifier reports a produced pair.

**Spec.** `reconciler_spec.rb` "does not report an implemented Job with a
running non-approval-blocking follow-up as drift" was red before. "still
reports an implemented Job with a running approval-blocking Workflow as drift"
passes. All 322 examples of `reconciler_spec.rb` and
`resilience_matrix_spec.rb` pass, with `RUN_CI_ONLY_SPECS=true` since both are
CI-only, as do the other `work_engine` specs.

**Lead L4 closed: no stall bug.** Read-only production queries, through the
database browser plugin's read-only query endpoint and the admin API, show
what happened:

- the operator paused the Job manually during the rebase storm, a minute
  before `agent_rebase` finished;
- the pause requested a stop at the WorkUnit's next phase boundary, which was
  `force_push` (`blocked_details` = `{pause_requested: true, phase_step_kind:
  force_push}`);
- runaway protection had been set four days earlier.

So the queued Step is a deliberate wait. The reconciler classified it as
`queued_step_without_run` and skipped the resume about once a minute: 16,596
detections and 8,298 skips since 2026-11-14. Main's "Leave queued Steps alone
while their gate recheck is still due" (`71c415f76a`) excludes deliberate
waits from that classifier, but it is not in the deployed build
(`a47a6abd37`). The churn stops on the next deploy.

---

## F90. AutoRetryJob and the stale-retry repair still disagreed about supersession — fixed

**Found by** DOC-44 retries, coverage item `stale-auto-retry-workflow`: "A
queued auto-retry Workflow is still waiting although its source was
superseded."

**Gap.** Three places decided whether an auto-retry's source Workflow was
superseded:

- `AutoRetryJob#stale_attempt?`, before launching the retry;
- the reconciler's `stale_auto_retry_workflow` classifier;
- the `CancelStaleAutoRetryWorkflow` executor.

F27 aligned the first two on "the source succeeded", after three intents
produced fourteen cancelled workflows. But the classifier and the executor
also count a source whose branch divergence was recovered by the current PR
branch (`branch_divergence_recovery.action == superseded_by_current_pr_branch`),
and `AutoRetryJob` did not.

Recovery skips pending `branch_diverged` attempts. But the operator's "retry
from the current PR branch" choice
(`mark_branch_divergence_retry_choice!`) passes
`cancel_stale_retry_workflows: false` and leaves them alive. A surviving
attempt then passed the launch check and started. The reconciler then
cancelled it as stale, which leaves a requested WorkIntent behind for the
launcher: the relaunch loop F27 described. The spec saw the attempt go ahead
to `RetryWorkflowEnqueuer`.

**Fix.** One predicate, `Workflows::AutoRetrySupersession.superseded?`: the
source succeeded, or was superseded by a later successful Workflow, or was
recovered by the current PR branch. `AutoRetryJob`, the classifier and the
executor all call it, so they cannot drift again. No Lean model: agreement
now holds by construction, and a model would only restate it.

**Spec.** `auto_retry_job_spec.rb` "skips an attempt whose source divergence
was recovered by the current PR branch" was red before (the retry was
performed).

Also run and green:

- the AutoRetryJob, recovery and attempt specs (100 examples);
- the CI-only reconciler, executor and resilience specs (350 examples);
- the `auto_retry_budget_exhausts`, `auto_retry_skip_clears_same_attempt_backoff`
  and `repeated_pr_open_failure_retry_recovers` simulations.

---

## F91. Sibling Runs reset each other's pinned deferral budget, so the loop could not end — fixed

**Found by** DOC-44 runs and queue, coverage item
`queued-run-placement-livelock`. A Run pinned to one host keeps deferring or
re-enqueueing itself and never starts. The plan frames it as a termination
argument, bounded by `PINNED_HOST_ADMISSION_DEFERRAL_BUDGET` (40).

**Gap.** `RunJob#record_host_admission_deferral!` kept the deferral count in a
single per-Workflow artifact, `run_host_admission`. It took the next count as
`prior.deferral_count + 1` only if `prior.run_id` was this Run, and otherwise
restarted at 1. `RunHostAdmission` resource-guards graders, and the
`WholeHostClaims` comment describes sibling grader shards of one Workflow
admitted within seconds of each other. On a pinned Workflow, siblings deferred
by the same host overwrite the artifact in turn, resetting each other's count,
so the budget never drops the storage affinity.

The spec alternated two sibling Runs for 40 rounds each, and the Workflow was
still pinned (`storage-a`).

Two things were already sound:

- When recording a deferral fails, the rescue returns a count of 1 for that
  call, but the stored count is untouched. That only delays exhaustion by one
  round.
- Reroutes do not count against the budget, by design.

**Fix.** The artifact keeps per-Run counts in `deferral_counts`, migrating a
legacy single count into it on first use. Each Run's `deferral_count` is its
own count. The top-level fields keep their meaning for other readers.

**Proved.** `PinnedDeferralBudget.lean` uses a budget of 4, three siblings and
every sequence of up to 12 deferrals:

- once some Run has been deferred `budget` times, affinity is dropped, so no
  interleaving defers forever;
- under the old shared counter, two alternating siblings never reach the
  budget in 3·budget rounds.

**Spec.** `run_job_spec.rb` "counts each pinned Run's deferrals separately so
siblings cannot reset each other" was red before.

Also run and green:

- the existing budget specs;
- all `spec/jobs` (849 examples);
- the CI-only reconciler deferral examples;
- the `pinned_host_admission_deferral_budget_reenqueues_elsewhere` simulation.

---

## F92. A started landing whose agent could not proceed kept the repository landing slot — fixed

**Found by** DOC-44 scheduling, coverage item `gates-starvation-free`. The
note there warns that the landing-slot release uses an allowlist, so any
reason that clears only from outside but is missing from the list keeps the
slot.

**Gap.** `WorkUnit#block!` gives back the repository `landing:` lock in two
cases:

- the reason is in `EXTERNALLY_CLEARED_BLOCKED_REASONS`, defined as "reasons
  that cannot clear by waiting";
- the landing had not started its first Run (NY7, `PrestartSlot.lean`).

When an approval-blocking Workflow is blocked because its agent reported it
cannot proceed, `Workflows::LifecyclePropagation#blocked!` blocks the unit with
`agent_cannot_proceed`. The landing Workflows (`auto_merge`, `merge_train`)
run a `landing_fix` repair agent, and that agent can report it cannot proceed.
`agent_cannot_proceed` clears only when a person or the agent acts. It meets
the list's own definition, but it was missing from the list. So a *started*
landing that ended up there kept the repository's landing slot, and every
other approved Job in the repository waited behind a Job nobody was working
on, with nothing marked failed.

Production (read-only): no blocked unit currently holds a landing lock, and no
landing Workflow has ever been `blocked`. The path is reachable, but has not
been taken.

**Fix.** `agent_cannot_proceed` joins `EXTERNALLY_CLEARED_BLOCKED_REASONS`.
Every reader of the list then treats it consistently:

- `block!` gives back the landing slot, and only that slot: the Job and Epic
  locks stay;
- the `externally_blocked_landing_slot` repair releases slots that units
  parked on it before this change still hold;
- `stranded_landing_job` returns such a Job to `approved` (M42).

**Spec.** `work_unit_spec.rb` "surrenders the landing slot when a started
landing's agent cannot proceed" was red before (the slot stayed held).

Also run and green:

- `spec/models/work_unit_spec.rb`, `spec/services/workflows` and the
  cannot-proceed tool spec;
- the CI-only reconciler, executor and resilience specs;
- the `stranded_landing_job_without_lock_returns_to_approved` simulation.
  There is no simulator scenario for the externally blocked landing slot
  itself; the reconciler spec covers that classifier and repair.

---

## F93. The plugin capability lookup treated every installed plugin as enabled when enablement could not be read — fixed

**Found by** checking main through `31254a466c` (the plugin capability-family
epic) against NY13. NY13 was decided: "We should not treat installed plugins
as enabled... retry until we have a straight answer."

The new private `PluginRegistry.available_capability_plugins` backs both
`capability_providers` (and so `Syrus::Plugin::Dispatch.call`) and
`capability_catalog`. It read the plugin records inside its own `begin`/`rescue
ActiveRecord::ActiveRecordError`, and on any database error kept every
installed plugin. That is exactly the fallback F-NY13 removed from
`providers_for`, `all_plugins`, `health` and `credential_types`. During a lock
timeout or a dropped connection, a family capability of a plugin the operator
had disabled was dispatched.

**Fix.** It now reads through `enablement_records`, like every other
enablement decision:

- declared defaults while the database or table does not exist;
- every plugin only for an asset build;
- otherwise retried, then `EnablementUnavailable`.

**Why the guard missed it.** The Lean model (`EnablementRead.lean`) proves the
read. That every enablement decision *uses* the read is a fact about call
sites, which the model cannot see. The behavioural specs pin only the methods
that existed then.
`spec/architecture/plugin_enablement_reads_fail_closed_spec.rb` now walks
`plugin_registry.rb` with Prism. It rejects any method that calls
`plugin_enabled?` and rescues a database error itself. One method is exempt,
`eager_load_skippable_plugin_names`, which fails toward loading more code. The
guard was red on the pre-fix code.

**Same rebase, same rule.** Main switched `providers_for` from `healthy?` to
`registrations_healthy?`, so a non-conforming family declaration withholds
only that family. This branch's `providers_with_owner_for` (plugin-hosted
points) documents "the same callable rule as providers_for" but still used
`healthy?`, so a plugin's hosted contributions vanished over an unrelated
family. It now uses `registrations_healthy?`.

**Specs.** Both were red before the fix:

- `capability_registry_spec.rb` "raises instead of offering a disabled
  plugin's capability when enablement cannot be read";
- `capability_registry_spec.rb` "keeps a non-conforming plugin's
  plugin-hosted contributions, like its other registrations".

Also run and green: `spec/lib`, `spec/architecture`, `spec/services/steps`,
the admin plugins request spec, and the `connected_accounts` and
`plugin_runtime` plugin specs (1,836 examples).

---

## F94. Family language detection called non-conforming providers, and a load error failed Prepare — fixed

**Found by** checking the same epic. It relies on this invariant: *a family
capability is only invoked through a conforming declaration*. `Dispatch`,
`LegacyBridge.providers_for_manifest` and `capability_providers` all check
`Conformance#conforming?` first.

`RepoPluginDetector#family_language_support?`, called from Prepare on every
workflow, resolved the declared provider by name and called its
language-support capability directly. Two counterexamples:

- **Non-conforming provider still claimed repos.** A provider that breaks the
  family contract (for example, an extra optional positional argument) still
  claimed the repository in both `detected_plugins` and the observed plugin
  signals.
- **A load error failed Prepare.** A family provider resolves lazily, so a
  provider file that fails to load raises `LoadError`/`SyntaxError`. That is a
  `ScriptError`, which the per-plugin `rescue StandardError` in `detect_among`
  let escape out of `record_detected_plugins!` and fail Prepare. That broke the
  detector's own contract: one plugin's failure must not take the detection
  pass with it.

No bundled plugin declares `family_provides` yet, so this was latent: an
external plugin or the first migrated bundled one would hit it.

**Fix.**

- Each manifest's declarations are checked with
  `Syrus::Plugin::Conformance.new([manifest])`. It is per manifest because
  `observe` deliberately includes disabled plugins, which the registry lookup
  omits.
- `detect_among` also contains `ScriptError`, the same pair `Conformance`
  contains.

**Specs.** Both were red before the fix, in `repo_plugin_detector_spec.rb`:

- "does not call a non-conforming declaration";
- "keeps detecting the other plugins when a family provider fails to load".

---

## F95. A closed Job's intent stayed requested when its unit was cancelled after the close — fixed

**Found by** coverage item `closed-job-open-intent`. Its note named the open
half: "an intent skipped because its unit was active is not re-cancelled when
the unit later ends".

**Evidence (production, read-only).** Two requested intents belong to closed
Jobs, each with a single cancelled unit:

- a `retry` intent whose unit was cancelled for `approved` (August). Its Job
  closed before the close-time cancel shipped, which today's close path would
  cancel.
- a `rebase` intent whose Job closed *50 seconds before* its unit was
  cancelled for `epic_wide_workflow_active` (September). This is the
  counterexample. F42, which covers specific reasons, is deployed and does not
  catch it.

**Cause.** Two writers end a Job-scoped intent, and each left this case to the
other:

1. `Job#cancel_stale_work_intents_after_close` cancels at close only intents
   with no active unit, and leaves the rest to their unit.
2. `WorkIntents::TerminalUnitSync` cancels on a unit cancellation only for
   `SUPERSEDING_CANCEL_REASONS`. It deliberately keeps an Epic-conflict
   victim's intent requested for its relaunch, and it never asked whether the
   Job had closed in the meantime.

Nothing relaunches work on a closed Job, so the intent was stranded.

**Fix.** `TerminalUnitSync` also cancels the intent when the cancelled unit
was its last active one and the intent's Job is closed. While the Job is open,
the Epic-conflict victim's intent is still kept for the relaunch.

**Proof.** `formal/SyrusModel/ClosedIntent.lean` models both writers with two
units and four outcomes:

- `after_closed_intents_have_owner`: over every sequence of up to six events,
  a closed Job's open intent always has an active unit.
- `before_strands`: replays the production order, close then a
  relaunch-keeping cancel.
- `open_job_keeps_relaunch`: pins that the victim relaunch still works while
  the Job is open.

**Spec.** `terminal_unit_sync_spec.rb` "cancels the intent of a closed Job
when its last active unit is cancelled for any reason" was red before the fix.
Also run and green: `spec/services/work_intents`, `spec/services/work_units`,
`spec/services/work_engine` (CI-only included), and the job, work unit and
work intent model specs (406 examples).

The two existing production rows are left alone. The reconciler's
`closed_job_requested_work_intent` classifier is the backstop for them, and
this mission repairs nothing by hand.

---

## F96. A finished Workflow deleted its workspace inside the finish transaction — fixed

**Found by** the failure sweep and coverage item
`running-workflow-nothing-left`. Its note recorded three
`finish_workflow_from_terminal_descendants` executions 20–250 s *after* their
Workflow finished as "unexplained, recheck after deploy".

**Evidence (production, read-only).** Over two days there were 27 such skips
("Workflow is succeeded, not running"):

- Most fire within a few seconds of the finish, a classifier snapshot racing
  the last Step. The repair skips correctly.
- Three were merge trains, 175, 206 and 251 s late.

The latest was the merge train that landed the plugin capability-family epic:

- It recorded `finished_at` 22:12:34.
- Four reconciler passes, at 22:13, 22:13:44, 22:14:30 and 22:15, still read
  it as running with every Step terminal. Their repairs failed on `Lock wait
  timeout exceeded`, from both `ReapStaleRunsJob` and
  `LandingQueueProcessorJob.lock_conflict`.
- Its final Run's log shows why: `[workspace] cleanup starting` at 22:12:38,
  then `[workspace] cleanup complete` at 22:16:05.

**Cause.** `Workflows::LifecyclePropagation` runs the AASM transition's `after`
hook inside the event's transaction. It called `workflow.cleanup_workspace!`
from `succeeded!`, `cancelled!`, `blocked!` and the infrastructure branch of
`failed!`. That cleanup `rm_rf`s the workspace and scratch directories, which
for a merge train took 3.5 minutes. For that whole time:

- the terminal state stayed uncommitted, so other processes saw a running
  Workflow with nothing left;
- the rows the same transaction had locked (the Workflow, its WorkUnit, and
  the member Jobs closed by `JobClosure.apply_pending!`) stayed locked;
- any failure in the deletion rolled back the terminal transition itself.

**Fix.** `Workflow#cleanup_workspace_after_commit!` defers `cleanup_workspace!`
with `ActiveRecord.after_all_transactions_commit`, which runs immediately when
no transaction is open, and contains its errors. If the process dies first,
`WorkflowWorkspacePruneJob` removes the directory, as it does any incomplete
cleanup. All four lifecycle paths use it. The direct callers (the admin
endpoint, the admin pending action and the prune job) are outside a
transaction and need its return value, so they keep the synchronous form.

**Spec.** `lifecycle_propagation_spec.rb` "removes the workspace only after the
succeed/cancel transition has committed" records the transaction depth inside
`WorkflowWorkspace.cleanup_for`. It was one level too deep before the fix.

No Lean model: this is about where I/O sits relative to a transaction
boundary, which the state models abstract away. The spec is the evidence.

---

## F97. A terminal WorkUnit and its intent committed separately — fixed

**Found by** coverage item `unit-intent-outcome-agreement`. Its note said that
making the intent sync part of the terminal transition would make the
disagreement states unreachable instead of repaired.

**Cause.**

- `WorkUnit#mark_terminal!` and `#preempt!` committed the unit's terminal
  state and lock release in a transaction, and only then called
  `WorkIntents::TerminalUnitSync`.
- When the call came from inside a Workflow transition, an outer transaction
  covered both and the result was atomic. A standalone call was not: an
  exception in the sync (a lock-wait timeout on the intent row, say) or a crash
  between the two left a finished unit with an open intent. Those are
  `succeeded_work_unit_unsatisfied_intent`,
  `failed_work_unit_unfailed_intent` and
  `superseded_work_unit_uncancelled_intent`.
- The Lean ownership model (`WorkUnits.lean`: `markTerminal`, `preempt`)
  already treats the sync as part of the same step, so its proofs assumed an
  atomicity the code did not provide on failure.

**Fix.** The sync runs inside both transactions. This adds no new lock order:
the sync only updates the unit's own intent, which the common path already
did inside the outer Workflow transaction. The only intent row lock
(`Launcher#instantiate`) precedes units of *other* intents.

**Evidence (production, read-only).** In 14 days there were 72
`superseded_work_unit_uncancelled_intent` repairs and none of the other two.
All 72 ran on 11-21, for units that finished 1–85 days earlier with
`job_closed` / `terminal_parent_work_unit`. That is F42's backstop draining
its backlog, not a live producer.

**Specs.** `work_unit_spec.rb` "does not commit mark_terminal! / preempt! when
the intent sync fails". Both were red before the fix: the unit committed as
terminal. Also run and green: the models, work intents, work units, work
engine (CI-only included), workflows, step dispatcher, jobs, landing and Epic
specs (3,878 examples).

**Still reachable (noted, not changed).** The sync skips while a sibling unit
of the same intent is active. If unit A succeeds while sibling B runs, and B
is then cancelled for a non-superseding reason, the intent stays open beside
a succeeded unit. It did not occur in 14 days. Which outcome the intent
should take then (A's success, or nothing because B was a newer attempt) is a
question about attempt semantics, so the classifier remains the backstop.

---

## F98. A dependency named webauthn made an infrastructure failure look like a provider auth failure — fixed

**Found by** the failure sweep. A main-branch grader for the external-reviewer
Epic's merge failed:

```
immutable source prepare command failed: npm ci
npm warn tar TAR_ENTRY_ERROR ENOENT: no such file or directory, lstat '.../node_modules/@...'
```

`RunFailureClassifier` filed it as `provider_auth_or_config`,
non-retryable. Nothing retried it, and `GraderCollect` does not count that
classification as an infrastructure failure, so the main grader recorded a
genuine failure on main over a transient extraction error.

**Cause.** `auth_or_config?` matched a bare `auth` substring. Its search text
includes the Run's recent logs, which contained the ordinary install lines
`Installing webauthn 3.5.1` and the deprecation warning for
`@github/webauthn-json`. Any repository with a WebAuthn or OAuth dependency in
its install log was exposed. The method's own comment records the same
mistake fixed earlier for `config` (`--mcp-config`) and `token`
(`x-access-token`).

**Fix.** `auth` is now matched as a word:
`\b(?:o?auth|authentication|authorization)\b`. "Authentication failed for
…", "OAuth token expired" and "auth error" still classify as auth/config.

**Specs.** `run_failure_classifier_spec.rb` (ci_only): the webauthn install
log example was red before; three genuine auth messages stay green. Also run
and green: the classifier-dependent specs (`declared_problems_are_known`,
`problem/kind`, `merge_train_failure_handler`, `rebase_attempt_guard`,
`problem_emission`, `repair_executor`, `auto_retry_job`).

**Not changed.**

- `permission denied` in the same pattern can also match a filesystem error
  in a log. That is a related false positive, noted for a separate change.
- An `npm ci` extraction ENOENT is still not classified as infrastructure.
  The prepare failure can be genuine (a broken lockfile), so it now falls
  through to the generic outcome rather than being guessed.
- What removed the files under the Step's immutable checkout mid-extraction is
  unexplained. It is the only such Run in two days.

---

## F99. Grader infrastructure failures were filed as provider auth failures — fixed (refines F98)

**Evidence (production, read-only, 14 days).** 35 Runs were classified
`provider_auth_or_config`, which is non-retryable. Six were *grader* Runs,
which never authenticate to an agent provider:

- three failed on `ActiveRecord::ConnectionNotEstablished: Can't connect to
  server on 'syrus-mysql'` (11-14);
- one failed on a missing table (11-14);
- two failed on `immutable source prepare command failed: npm ci` (11-19,
  and the 11-22 one in F98).

Every one is an infrastructure failure, and none was retried. Each log
contained `webauthn`, which F98 already handles. Two also contained the test
name "automatically exchanges Codex OAuth callbacks", which F98's word-bounded
`\bo?auth\b` still matched.

**Fix.** `auth_or_config?` no longer accepts a bare auth word at all. It needs
a failure phrasing: `(o)auth(entication|orization)` followed by failed,
failure, error, required, denied, rejected, invalid or expired. These still
classify as auth/config:

- "Authentication failed for …";
- "auth error";
- the `authentication_failed` agent outcome;
- "OAuth token expired" (through the existing token pattern).

**Spec.** `run_failure_classifier_spec.rb` "does not treat a test name
mentioning OAuth in grader output as provider auth/config" was red before.
The classifier spec (121 examples, CI-only included) and its dependants are
green.

---

## F100. Two main-branch repairs ran at once after a repair failed with a retry pending — fixed

**Evidence (production, read-only, 11-22 UTC).** Main-branch repair Job 9775
had been retrying since 13:00, while worker pods kept dying (M59):

- Workflow 66277 failed;
- Workflow 66284 failed at 15:38:37, with an auto-retry scheduled;
- at 15:40:20 a health signal spawned a **second** repair Job, 9786
  (Workflow 66298);
- at 15:43 the auto-retry relaunched 9775 as Workflow 66299.

Both repairs then ran, each with a preflight fan-out of 134 graders, beside a
main grader with 134 more, on workers that were already being lost. Main
grader 66295 had *succeeded* at about 14:20. Only the stale `ci_health:
broken` from before main's hand fix kept repairs being spawned.

**Invariant.** At most one main-branch repair is in progress per repository.

**Cause.** `MainHealthChangedService#ensure_repair_job!` treats a repair Job
as blocking only in `BLOCKING_FIX_JOB_STATES`, which are the active and
landing states. Between a repair Workflow's failure and its auto-retry, the
Job is `failed`.

- `failed_fix_job_for_current_sha` only suppresses a failure *for the current
  SHA*, and 9775's covered an older commit.
- The `MAX_OPEN_FAILED_FIX_JOBS` cap allows several failed repairs.

So a health signal in that window spawned a new repair, and the retry then
revived the old one.

**Fix.** A failed repair Job with a pending `AutoRetryAttempt` now blocks
spawning (`retrying_fix_job`), just as an active one does.

**Spec.** `main_health_changed_service_spec.rb` (CI-only) "does not spawn
another fix Job while a failed repair has a pending auto-retry" was red before.
"Spawns another fix Job after main advances past a failed repair SHA", the same
setup without the pending retry, still spawns. The spec file (114 examples)
and the repair, auto-approver, preflight-collect and auto-retry specs are green.

**Not changed.** Whether the duplicate load is what killed the pods is
unproven (M59). What kept repairs coming was a stale `ci_health` while the
grader said healthy. That is a question about which signal wins, and it is
not changed here.

---

## F101. A started landing paused by hand kept the repository landing slot — fixed (NY27)

**Decision (NY27, A).** A paused started landing gives the slot back. On
unpause it re-acquires it, waiting its turn if another landing took it.

**Before.** `WorkUnit#block!` surrenders `landing:repository:<id>` for
`EXTERNALLY_CLEARED_BLOCKED_REASONS`, or for any block before the first Run
(NY7). `manual_pause` was in neither list once a Run existed. So a started
landing paused by hand kept the slot for as long as the pause lasted, and
every other approved Job in the repository waited behind work nobody was
doing (`PrestartSlot.started_before_starves_on_manual_pause`).

**Fix.**

- `manual_pause` joins `EXTERNALLY_CLEARED_BLOCKED_REASONS`, so a hand pause
  surrenders the landing slot. Job and Epic locks stay: they stop a second
  attempt at the same work.
- `JobManualPause.unpause!` re-acquires through `resume_for_workflow!`, as
  before. If another landing took the slot, that raised `LockConflict` out of
  the unpause; it now leaves the unit queued without the slot. Its next Run
  start takes it through `WorkUnit#mark_running!`, and `RunJob` already
  defers a start whose lock is held, so the landing waits its turn.
- The same gap applies to F92's `agent_cannot_proceed`, whose release is
  re-acquired through the same `resume_for_workflow!` paths that already
  rescue `LockConflict` elsewhere. It is not changed here.

**Proof.** `PrestartSlot.lean` gains the after-start case.
`started_after_never_starves`: with `manual_pause` in the list, no indefinite
block keeps the slot after the first Run either. Mutual exclusion stays the
lock's unique index (`LockSafety`).

**Specs.** All three were red before:

- `work_unit_spec.rb`: "surrenders the landing slot when a started landing is
  paused by hand";
- `job_manual_pause_spec.rb`: "takes the landing slot back on unpause when it
  is free";
- `job_manual_pause_spec.rb`: "waits its turn on unpause instead of failing
  when another landing took the slot".

Also run and green, CI-only included: `spec/services/work_units`, the landing
queue processor, `spec/services/work_engine`, `run_job_spec` and `job_spec`.

---

## F102. Recovering a lost Step-failure cascade hard-failed the Workflow — fixed (NY26)

**Decision (NY26, A).** The repair replays the cascade.

**Before.** When a Step fails, `StepDispatcher#fail!` decides what that means:
advance, the next loop iteration, an in-place infrastructure retry, a try
branch, or (only when none applies) a hard fail. When that cascade was lost,
the reconciler's `fail_workflow_from_failed_step` called `Workflow#fail!`
directly. So a lost cascade on a Step whose worker died failed the Workflow
and its Job, where the live cascade would have re-run the Step in place
(`CascadeReplay.repair_before_diverges`). A spec pinned that behaviour for a
retryable `agent_resume_unavailable` Run.

**Fix.** `FailWorkflowFromFailedStep` calls
`StepDispatcher.fail_from(failed_step)`, the function the live path uses, and
reports the Workflow state it ends in. The planner's description and execution
steps say so. The guards are unchanged: no live descendants, a failed Step that
is not a superseded loop iteration, and a Workflow that may fail.

**Proof.** `CascadeReplay.lean`.

- `repair_after_agrees`: the repair reaches the live outcome on every input.
- `replay_terminates`: repeated loss and replay cannot loop. Each in-place
  retry adds a Run, and `INFRASTRUCTURE_STEP_RETRY_LIMIT` refuses the retry
  once the count passes it, so a Step gets at most `limit` replayed retries
  before the replay ends in a try branch or a hard fail.

**Specs.**

- `reconciler_spec.rb`: "replays the lost cascade for a running workflow with
  a failed step and a queued tail" was red before. It is the old pinned
  example, now expecting a re-run instead of a failed Workflow.
- `reconciler_spec.rb`: "hard-fails a running workflow whose failed step the
  cascade would not retry" was red only on the new message. It pins the
  hard-fail case.
- The queued-Workflow sibling keeps its hard-fail outcome; only its message
  changed.

Also run and green, CI-only included: `spec/services/work_engine` and
`step_dispatcher_spec` (859 examples).

---

## F103. A plugin signed by one publisher installed under another's name prefix — fixed

**Before.** A registry trust store binds each publisher key to one name prefix
(the part of the plugin name before the first underscore). The listing,
`PluginRegistryClient#parse_entries`, accepts an entry only when the publisher
it *declares* owns that prefix. The detached signature names its own key, and
`Syrus::PluginPackage::Verifier` accepted any key in the trust store. So a
package signed by publisher B, listed under publisher A's prefix, installed
with B's trust label (`SignerPrefix.before_admits_foreign_signer`).

The index repository's CI check (`syrus plugin index check`) ties the
signature to the declared key. Syrus serves any configured registry, though,
and does not get to assume that registry runs the check.

**Fix.** `Verifier#owns_name?`: when a name is given, a registry package's
signer must own its prefix, the listing's rule. A signed local upload is held
to its signer's prefix when the signer declares one. `TrustStore.name_prefix`
is the one place both read the prefix from. Public and searchable plugin docs
say so.

**Proof.** `SignerPrefix.lean`: `after_registry_signer_owns_prefix` (the
install rule is exactly the listing's rule, now applied to the signer) and
`after_local_respects_declared_prefix`.

**Specs.** `verifier_spec.rb` "name prefix ownership": three examples red
before (another prefix, no prefix, local upload with a declared prefix). Two
fixtures had a registry publisher with no prefix signing `weather`, which the
listing can never accept; they now declare `weather`. Plugin package,
installer, registry, artifact and admin request specs: 414 examples, 0
failures.

---

## F104. Naming a registry without a version staged its oldest stored release — fixed

**Before.** `PluginInstaller#stored_release` picks the newest version when no
version is given. When a registry was named, it filtered by registry and
returned `candidates.first`, before the version selection, so
`stage_release!("acme_weather", registry: "partner")` staged whichever release
was stored first (1.0.0, with 2.0.0 stored).

**Fix.** The registry filter only narrows the candidates; the newest-version
selection runs on every path, and a named registry then takes its candidate
without the canonical/ambiguity tie-break.

**Spec.** `plugin_installer_spec.rb` "stages the newest stored release of a
named registry when no version is given" was red before (got 1.0.0).

---

## F105. Merge-train base-move recovery was not bounded by its nesting — fixed

Found while designing NY29, which reuses the same Try-branch mechanism.

**Before.** `merge_train_land_with_rebase_recovery` bounds base-move recovery
by nesting: each attempt is a Try whose branch ends in the next attempt, and
the last attempt (`BASE_MOVE_RECOVERY_ATTEMPTS`) is a plain
`merge_train_land_after_rebase` Step. `StepDispatcher#try_node_for` matches a
Step without a `try_id` to any Try of its kind, a fallback for Steps created
before `try_id` existed. Steps a branch inserts for plain nodes carry no
`try_id`, so the last attempt matched the nested Try of the same kind and
expanded its branch again, which ends in another plain Step of that kind. A
base that kept moving got recovery rounds without end
(`BranchBound.before_unbounded`).

**Fix.** `materialize_branch_steps!` marks a Step it inserts for a plain node
(`try_branch_plain_step`), and `try_node_for` never matches a marked Step
without a `try_id`. The fallback stays for up-front Steps.

**Proof.** `BranchBound.lean`: `fixed_bounded` (from the top Try, recovery
expands exactly `k` times for `k` attempts).

**Spec.** `step_dispatcher_spec.rb` "hard-fails the plain land at the bottom of
the recovery nesting instead of expanding again" was red before (12 Steps
became 17). Dispatcher spec, CI-only included: 244 examples, 0 failures.

---

## F106. A stacked Job's conflict with its restacked parent burned retries — fixed (NY29)

**Decision (NY29, A).** On a rebase conflict, run an agent conflict resolution
in the same workspace, and fail only if the agent cannot resolve it.

**Before.** `pr_open` replays a stacked Job's finished work onto the parent's
live head (`StackBaseFreshness`). A conflicting replay was reported as
`awaiting_stable_base`, which is retryable, so the auto-retry ran the same
mechanical replay and conflicted again. The agent path
(`StackRebaseCoordinator` → Rebase Workflow) skips children without a PR, and
`stack_agent_rebase` resets each branch to its remote copy, which an
unpublished child does not have. A production Epic stalled this way for days
(`StackConflictRecovery.before_never_publishes`).

**Fix.**

- `StackBaseFreshness::RebaseConflict` now fails `pr_open` with
  `stack_base_rebase_conflict`, a non-retryable Problem whose remediation is a
  branch, and sets it as the Step's failure code. The parent that keeps moving,
  and the replay that fails validation, stay `awaiting_stable_base`.
- `Workflows::Base.stack_aware_pr_open` wraps `pr_open` in a Try for every
  chain that opens a new PR (Initial, Retry, coding and local-mode handoff,
  main-branch repair, base-refresh retry). Its branch is
  `stack_base_agent_rebase → grade loop repaired by landing_fix → pr_open`,
  the follow-up push's shape.
- `Steps::StackBaseAgentRebase` (agentic, rebase-conflict role) fetches the
  parent's current head and starts the same replay. It skips the agent if the
  replay now applies. It requires a finished rebase, a clean tree and a HEAD
  that descends from the parent, then records that head as the prepared base,
  so the trailing `pr_open` finds the branch fresh.
- The trailing `pr_open` is a plain branch Step, so with F105 a second
  conflict fails the Workflow rather than resolving again.
- Docs: `workflow_steps.md` (`pr_open`, `stack_base_agent_rebase`) and the
  website's workflow page.

**Proof.** `StackConflictRecovery.lean`: `after_resolved_publishes`, and
`after_terminates` (every path ends within two `pr_open` attempts and never
as an exhausted retry budget).

**Specs.** All red before:

- `pr_open_spec.rb` "hands a conflicting stack-base rebase to the agent branch
  instead of awaiting a stable base";
- `workflows_spec.rb` "wraps the initial pr_open in a try that resolves a
  stack-base conflict with an agent";
- `kind_spec.rb` "treats a conflicting stack-base rebase as a non-retryable
  problem handled by a branch";
- `step_dispatcher_spec.rb` "resolves a stack-base conflict in pr_open with an
  agent, once";
- `stack_base_agent_rebase_spec.rb` (new, real git): the agent resolves a real
  conflict; an unresolved rebase fails; a parent that moved past the conflict
  replays without the agent; no recorded conflict refuses to run.

Ten pinned template specs now match the Try node through
`spec/support/stack_aware_pr_open.rb`. Run and green, CI-only included: the
dispatcher, workflows, Problem, Step kind, agent role, checkpoint publisher,
stack freshness and stack rebase coordinator specs (852 examples); the work
engine and the throughput plugin (697); the docs architecture specs; and
`bin/check-plugin-boundaries`.

---

## F107. A dependency could make an Epic wait for itself through an outside Job — fixed (NY28)

**Decision (NY28, A).** Reject it when the dependency is created, treating
each Epic as one node, with an error naming the Epic and the outside Job.

**Before.** `JobDependency#no_cycle` rejected cycles between Jobs only, and
`EpicDependency#no_cycle` between Epics only. So Epic child A <- outside Job B
<- Epic child C (B needs A, C needs B) was accepted. The Epic's train waits for
B, and B waits for A, which only lands with that train, so neither ever lands
(`LandingUnitCycle.lean`, which also proves that rejecting cycles in the
Epic-contracted graph is exactly what guarantees progress).

**Fix.** `JobDependency::LandingUnitGraph` is the dependency graph with each
Epic contracted to one node, with edges from resolved JobDependency rows
(to a Job or an Epic) and EpicDependency rows. Edges inside one Epic are left
to `linear_chain_within_epic`. `JobDependency#no_cycle` now also rejects a new
edge between two different units when its target already reaches its
source, including a dependency on an Epic itself. The row being changed is
left out of the search. Public and searchable merge-train docs say so.

**Specs.** `job_dependency_spec.rb` "cycles through an Epic as one landing
unit": three rejections red before (child -> outside -> child, in either
creation order, and an outside Job depending on the Epic itself); two
acceptances pin that an outside Job between children the Epic does not wait
for, and the Epic's own chain, stay valid. Run and green, CI-only included:
the dependency and Epic models, Epic services, proposal materializer, parser,
landing order and Job specs (533 examples), and the dependency request specs
(394).

---

## F108. A plugin tool could skip the generic approval with a bare approval_effect claim — fixed (NY12)

**Decision (NY12, A; follow-up A).** Honour `approval_effect` only for core
tools and for tools whose confirmation card is a registered pending action.
Give the Coworkers spawn tools pending-action classes.

**Before.** `approval_effect` skips the generic "ask" request because the
tool's only mutation is creating the owner's confirmation card; policy still
runs and a deny still refuses it. A plugin tool-set definition could set the
flag (`Mcp::CoworkerToolCatalog`), and nothing checked that the tool creates a
card, so a plugin tool could declare it and run on "ask" with no confirmation
(`ApprovalEffectBacking.before_bare_claim_skips`). Only the Coworkers spawn
tools used it, and they created a generic `coworker_tool_call` card.

**Fix.**

- `AuthorizationSupport.approval_effect_backed?`: a core tool's flag stands;
  a plugin descriptor's flag counts only when `PendingActions.registered?`
  finds a pending action under the tool's name.
- `PendingActions::SpawnCoworkerChat` and `PendingActions::SpawnSyrusChat`
  (subclasses of `CoworkerToolCall`) are registered under the tool names, and
  both spawn tools create their cards under those keys. The card's approved
  re-run is unchanged, so there is still exactly one card.
- Everything that keyed on `coworker_tool_call` now takes the family: the
  pending-action whitelist, smart decisions, the outcome notification, the
  admin capability inventory (core, `ChatPendingAction::COWORKER_TOOL_CALL_ACTIONS`),
  and the approval inbox and spawn caps (plugin,
  `PendingActions::CoworkerToolCall.family_action_keys`). The caps still count
  cards created before the change.
- Docs: the Coworkers docs and the plugin authoring guide.

**Proof.** `ApprovalEffectBacking.lean`: `after_skip_implies_backed` (the ask
is skipped only for a backed effect) and `after_backed_claim_skips` (the
spawn tools keep one card).

**Specs.** Red before: `authorization_support_spec.rb` "still asks through the
generic request when no pending action is registered for the tool" and "leaves
the card to the tool when the plugin registers its pending action";
`spawn_chat_tool_spec.rb` "creates its card as its own registered pending
action" and the reservation pin; `spawn_syrus_chat_tool_spec.rb`'s one-card
pin. New: the outcome notification for each card kind. Run and green, CI-only
included: the Coworkers plugin, pending actions, permissions, MCP registry,
chat MCP, admin, chats request and architecture specs (3,147 examples), and
`bin/check-plugin-boundaries`.

---

## F109. A queued CI repair held behind a main repair of a superseded base waited forever — fixed

Found checking main's `39f7f9c254` (M65).

**Before.** The CI repair gate parks a repair on `base_not_known_healthy` or
`base_repair_active` while its own base is unproven. Once main has moved past
that base, neither can clear, and the repair is moot. Main taught the running
path (`RepairExecutor#cancel_superseded_ci_repair`) the second kind, but the
queued path (`CancelSupersededCiRepair`), the reconciler's detection
(`superseded_ci_repair_start_block?`) and the planner's precondition still
accepted only the first. A repair still queued behind a stale main repair, and
the approved Job's landing behind it, waited forever
(`SupersededCiRepair.queued_before_parks`).

**Fix.** `CiRepairSafety::SUPERSEDABLE_BLOCK_KINDS` is the one list; the
running and queued paths, the reconciler's detection and the planner's
precondition read it. The issue evidence records the block kind.

**Proof.** `SupersededCiRepair.lean`: `after_cancels_exactly_moot` and
`after_phases_agree` (the queued and running paths agree on every block kind).

**Spec.** The simulation `superseded_ci_repair_behind_main_repair_resolves`
and `scenario_runner_spec.rb` "cancels a queued CI repair held behind a main
repair once its base is superseded", red before. `spec/services/work_engine`
and `spec/services/work_units`, CI-only included: 815 examples, 0 failures.

---

## F110. One global row-lock order, enforced by the suite (NY25)

**Decision (NY25, A).** Adopt the order AppSetting → Epic → Run → Job →
WorkIntent → Workflow → Step → WorkUnit → User, fix the inverted sites, and add
a test-mode checker that fails a transaction taking locks out of order.

**The checker.** `Syrus::LockOrder::Checker` (`lib/syrus/lock_order.rb`,
installed by `spec/support/lock_order.rb`) hooks locking relation queries,
which `lock!` and `with_lock` go through. Inside the application's outermost
transaction (the first joinable one, so a transactional test's wrapper does
not count) it tracks the highest-ranked model and the rows locked so far, and
fails on a lock of a lower-ranked model unless every row it returns is already
held. The failure names both lock sites. `PENDING_DECISION` lists the
inversions waiting on NY31-NY33; those are recorded, not raised.

**What the suite found.** Two record-mode runs over the whole suite, CI-only
included, found 13 inversion kinds. The audit's four:

- `TerminalWorkflowSync` held the Workflow and drove it through
  `Workflow#start`, which locks the Job (30 hits): now Job, then Workflow.
- `LandingQueueProcessor#release_blocked_landing_slots!` locked the Workflow,
  then the Job: now Job first.
- `PlannedExecutionOverrides::Operation` locked the Job and Workflows, then
  Runs (14 hits): now Runs, then the Job, then Workflows.
- `RetryFailedStepEnqueuer` held the Job when the merge-train rebuild locked
  the Epic: it now locks the train's Epic first.

Two more the audit had missed, also fixed:

- `LandingValidationPrefetcher` locked the source Workflow, then the target's
  Jobs (9 hits): now the Jobs (in id order), then the Workflow.
- `RepairExecutor#audit!` locked a Run inside whatever transaction the repair
  ran in (under a held Job or WorkUnit): the audit line is now appended after
  the outermost commit, so a rolled-back repair is not audited as applied.

Three need a decision, filed as NY31 (the User row as provider-reservation
mutex, 158 hits), NY32 (a terminal WorkUnit cancelling its Workflow inside the
unit's transaction, which F97 introduced; 4 hits) and NY33 (the cancellation
cascade locking a descendant Workflow after its parent's Steps; 4 hits).

**Proof.** `LockOrder.lean` already proves the decided order acyclic and that
it inverts exactly the four audited edge kinds; the suite now checks the code
against it.

**Specs.** `spec/lib/syrus/lock_order_spec.rb` (10 examples: in-order locks,
an inversion, locking relations, nested transactions, separate transactions,
same-model locks, re-locking a held row, another row after a higher rank, the
pending list, record mode). Switching the checker to raise turned 23 existing
specs red (terminal workflow sync, landing prefetcher, planned-execution
overrides, the merge-train retry); all green after the fixes. Full suite with
the checker raising, CI-only included: 24,726 and 5,316 examples, 0 failures.
Contributor guidance: `docs/engineering/conventions/database-and-migrations.md`.

---

## F111. An abandoned backup upload protected its backup forever — fixed (NY21)

**Decision (NY21, A).** Keep deletion conservative, and add a sweep that marks
a replication failed once its lease has expired and its destination is no
longer configured.

**Before.** `LocalBackups::Retention` never deletes a backup with an
`uploading` replication. Leases last six hours and are never renewed, and
nothing expired them, so a replication whose worker died stayed `uploading`
until the same destination pinned again. A destination removed mid-upload never
does, so its backup was protected from retention and capacity reclamation
forever (`AbandonedReplication.before_pins_forever`).

**Fix.**

- `Syrus::Plugin::BackupDestination` gains two optional methods (1.x, additive):
  `identity`, the destination identity it pins under (default nil), and
  `configured?` (default true). The S3 destination answers both.
- `LocalBackups::AbandonedReplicationSweep` marks failed an `uploading`
  replication whose lease has expired when no enabled destination that is
  configured claims its identity. It releases nothing while any enabled
  destination does not declare an identity, and it locks the Backup before the
  replication (as `ArtifactSource.pin` does), rechecking the lease under the
  lock.
- `LocalBackups::MaintenanceJob` runs it before retention, so the released
  backup is reclaimable in the same pass. Docs: Local Backups.

**Proof.** `AbandonedReplication.lean`: `never_releases_live`,
`releases_abandoned`, `anonymous_destination_releases_nothing`.

**Specs.** `abandoned_replication_sweep_spec.rb` (new, red before: the sweep
did not exist): a gone destination, an unconfigured one, a live one kept, an
active lease kept, an anonymous destination releasing nothing, and the
maintenance job order. `destination_spec.rb`: the S3 identity and
configuration. Run and green, CI-only included: both plugins, `spec/lib/syrus`
and the architecture specs (1,059 examples), and `bin/check-plugin-boundaries`.

---

## F112. Recovery preflight was ready when compatibility was unknown — fixed (NY22)

**Decision (NY22, A).** Treat every unknown as a failure, and allow it only
with an explicit operator flag named after what is unknown.

**Before.** `LocalBackups::Recovery::Preflight` issues the restore token only
when no check fails, and `restore` requires that token. A known mismatch
failed, but a missing fact only warned: the destination's database adapter,
database version or application version not supplied; no compatibility range
in the bundle, or versions that do not parse; no encryption-key fingerprints in
the bundle. Warnings needed no acknowledgement, so preflight was ready and a
restore could replace the database of a destination whose compatibility was
never established (`RecoveryPreflight.before_ready_with_unknowns`).

**Fix.** Each unknown carries a code (`UNKNOWN_CODES`) and fails unless the
operator passes `--allow-unknown-<code>` to `bin/disaster-recovery`, which turns
it into a warning that names the flag. An unrecognised code is refused. The
uncountable in-flight work warning is left as a warning: it means the database
is unavailable, which is the usual disaster-recovery case, and it is not a
compatibility fact. Docs: Local Backups and the Docker Compose deployment page.

**Proof.** `RecoveryPreflight.lean`: `ready_implies_accepted` (a ready
preflight has no unaccepted unknown) and `one_flag_excuses_one`.

**Specs.** `recovery_spec.rb` "unknown compatibility" (red before: the
argument did not exist): ready when everything is known, each of the five
unknowns blocked and then accepted by its own flag, and one flag not excusing
another. The token spec now accepts its bundle's three unknowns explicitly.
`spec/bin/disaster_recovery_spec.rb` drives the CLI: blocked, still blocked
with only one of two flags, ready with both. Local Backups specs: 94 examples,
0 failures.

---

## F113. A hook the Job's branch added ran on the reviewer's machine — fixed (NY23)

**Decision (NY23, A).** Run a hook without asking only if the same command is
already in the `.syrus.yml` on the Job's base branch; show any new or changed
hook and ask, refusing without a terminal unless `--hooks` is passed; and gate
on an allow-list of kinds (issue, direct, cron).

**Before.** `syrus checkout` ran every `hooks.post_checkout` command from the
checked-out branch's `.syrus.yml` files, unless `--no-hooks` was passed or the
Job was an `external_pr` (a deny-list). Every other branch is written by an
agent working from issue text, so on a repository that accepts outside issues
the issue author could steer the agent into adding a hook that ran on the
reviewer's machine before the diff was read. An unknown or missing kind ran
hooks too (`CheckoutHooks.before_runs_agent_hook`, `before_runs_unknown_kind`).

**Fix (Go CLI).**

- `postCheckoutHooksAllowed` is an allow-list of `issue`, `direct` and `cron`.
- `runPostCheckoutHooks` resolves and fetches the base branch once
  (`postCheckoutBaseRef`), and for each `.syrus.yml` reads the same file on it
  (`git show`) to get the trusted commands. A command not among them is asked
  about on a terminal and skipped without one, with a message naming `--hooks`.
  When the base branch cannot be read, every hook counts as new.
- `--hooks` on `syrus checkout` and `syrus job checkout` runs new and changed
  hooks without asking and skips the lookup. The Epic paths get the same policy.
- Docs: the website's configuration page, `config/syrus_docs/syrus_yml.md`, and
  the regenerated CLI catalog.

**Proof.** `CheckoutHooks.lean`: `after_unasked_only_if_on_base` and
`after_unknown_kind_never_runs`.

**Tests.** `cli/cmd/checkout_hook_trust_test.go` (new, red before: the options
did not exist): a hook already on the base runs unasked, a new one is refused
without a terminal, a changed one counts as new, the prompt decides on a
terminal, `--hooks` runs it, an unreadable base trusts nothing, the kind
allow-list, and the command-level default. Thirty-five existing fixtures sent a
Job with no `kind`, which the allow-list now refuses; they declare
`"kind":"issue"`, as the API does. Four tests that exist to run hooks now pass
`--hooks` (or `allowUntrusted`). All CLI packages pass, and `go vet` is clean.

---

## F114. A backend update deleted the image it had just replaced — fixed (NY24)

**Decision (NY24, B).** Keep the previous image only until the next successful
update, or for a fixed period such as 7 days.

**Before.** After a backend update passed its health gate, the desktop removed
every same-channel backend image except the new pin
(`removeSupersededSyrusImages`), including the image that had been running a
minute earlier. A version that misbehaved after the health gate (a migration or
runtime problem) could only be rolled back by re-pulling about 7.6 GB, which
may be impossible offline.

**Fix (desktop).**

- `updateBackend` captures the pin it is replacing before the installer runs.
  After a healthy update it writes `image-retention.json` in the state
  directory (`retentionAfterUpdate`: the replaced ref, kept 7 days) and passes
  that ref to the cleanup, which keeps it. The record replaces the last one, so
  the image an earlier update kept is retired by the next update.
- `ensureRunning`, the launch check, retires the kept image once its deadline
  has passed, on a healthy stack only; a broken stack keeps every image.
- Retention is best-effort like the cleanup it feeds: a lost or corrupt record
  only means the image is not kept.
- Docs: the website's Desktop and Troubleshooting pages.

**Proof.** `RollbackImage.lean`: `at_most_one_kept`, `update_keeps_replaced`,
`second_update_retires_first`, `expired_retired_at_launch`.

**Tests.** `desktop/src/imageRetention.test.ts` (red before: the module did not
exist): the seven-day record, no record without a changed pin, expiry
(including an unreadable deadline), the filter keeping the retained image and
removing older ones, and the record's round trip. `imageRetentionLaunch.test.ts`
drives `ensureRunning`: an expired record is retired, an active one is kept, no
record does nothing; removing the launch call turns it red. Desktop suite as CI
runs it (`npx vitest run desktop/src`): 46 files, 318 tests, 0 failures; the
desktop typecheck is clean.

---

## F115. The merge-train evidence model had drifted from the code — model fixed

Found by the first conformance fixtures (formal/INTEGRATION.md, layer 3).

**Before.** `TrainEvidence.lean` mirrors `Steps::MergeTrainLand#member_landed?`.
When a member's last recorded commit is not an ancestor of the integration SHA,
the model accepted only patch equivalence to the base. The Ruby had since
gained a second piece of evidence there, `rebased_into_integration?`: a
rebased train gives every integrated commit a new SHA, so a commit with the
same patch-id in what the train integrated counts as landed. The model's
theorem, "marked merged implies evidence", was about a function the code no
longer was. The code was right; the model was stale.

**Fix.** The model gains `rebasedIntoIntegration` in its `notAncestor` case and
in `evidence`; `after_merged_has_evidence` still holds over every member.

**Conformance.** `formal/fixtures/train_evidence.json` holds the model's verdict
for all 48 combinations of the evidence inputs, and
`spec/formal/train_evidence_conformance_spec.rb` runs the real `member_landed?`
on each (the git-backed leaves stubbed) and agrees on all 48. Run against the
old model's answers, it fails on exactly the two cases the old model missed.
`spec/formal/auto_approval_conformance_spec.rb` does the same for
`AutoApproval.approveNew` and `AutoApprovalRule#approve_after_grader_success!`
(8 cases, all agree). Both methods are now in `formal/mirrors.yml`.

---

## F116. The review-barrier model had one way to pass where the code has three — model fixed (Lead L12)

**Before.** `ReviewBarrier.lean` passed the required-review barrier only when
the tracked HEAD was approved. `Workflows::ImmutableReviewHeadBarrier.satisfied_for?`
also passes a required review that reacted without changing HEAD, and one whose
budget exhaustion was recorded for that HEAD, with a high-severity warning. So
the model's headline, "whatever is pushed was approved by every required
review", described a barrier the code is not: under exhaustion it is false by
design. The code was right; the model was stale.

**Fix.** An `Evidence` section models `satisfied_for?` for one required review
with all three paths. `pass_is_approval_reaction_or_exception` restates the
promise exactly, `pass_without_exception_is_reviewed` keeps the strong form
when no exhaustion was recorded, and `exhaustion_passes_unreviewed` names the
exception. The step-sequence counterexamples are unchanged.

**Conformance.** `formal/fixtures/review_barrier.json` holds the verdict for all
32 combinations of one review's evidence, and
`spec/formal/review_barrier_conformance_spec.rb` runs the real `satisfied_for?`
on each (the record lookups stubbed): all 32 agree. Run against the old model's
answers it fails on exactly the 9 cases where they differ. `satisfied_for?` is
now in `formal/mirrors.yml`.

## F117. A lock on a row the transaction created is outside the order (NY32)

**Before.** NY32 assumed `WorkUnit#mark_terminal!`/`#preempt!` held the unit while
`TerminalUnitSync` cancelled the unit's own Workflow and Steps. It no longer
does: `TerminalUnitSync` only settles the WorkIntent. With NY32's exemption
removed, the full suite (parallel and CI-only) has exactly one hit, two examples
of restarting a Job (`Api::V1::App::JobLifecycleController#restart`). One
transaction closes the old Job, which preempts its WorkUnit and locks that row,
then creates the replacement Job and launches it, which locks the Workflow and
Step it just inserted.

**Why it is not a deadlock.** A row a transaction inserted is invisible to every
other transaction until commit. Nobody else can lock it first, and its creator
never waits for it, so the lock adds no edge to the wait-for graph. The decided
option A (lock the Workflow and Steps before the unit) would not have touched
this hit, since the Workflow locked late is a different Job's.

**Fix.** The checker now records the rows each application transaction inserts
(`Syrus::LockOrder::Checker::CreateTracking`) and skips the order check for a
lock whose rows are all self-created; such rows are not counted as held either.
NY32's `PENDING_DECISION` entry is gone with no change to `WorkUnit`.

**Proof.** `LockOrder.lean`, section `SelfCreated`: `self_created_never_waits`
and `waits_only_on_committed_rows`. A transaction waits for a row only if it can
see the row and the other transaction holds it, which needs the other to see it
too; only committed rows satisfy both.

**Specs.** `spec/lib/syrus/lock_order_spec.rb` "exempts rows the transaction
created itself" (red before the checker change) and "still checks a
pre-existing row taken after a self-created one". The two restart examples in
`spec/requests/api/v1/app/job_lifecycle_spec.rb` pass in raise mode.

## F118. The queue snapshot missed jobs promoted while it read — fixed

**Before.** The reconciler's SolidQueue snapshot reads the five execution tables
in separate queries: ready, claimed, failed, scheduled, blocked. SolidQueue moves
a job forward atomically (scheduled or blocked to ready, ready to claimed,
claimed to failed), but a move that lands between two reads leaves the job in
neither when its new table was read before its old one. A job the dispatcher
promoted from scheduled or blocked to ready after the first read was seen
nowhere and classified `queued_run_with_orphaned_queue_job`. The repair deletes
that SolidQueue job by id with no re-check and re-enqueues the Run. That deletes
a healthy job, and if a worker claimed it meanwhile, the Run gets a second RunJob.
Main's `600a716d44` added a 2-minute grace on the job's age, which does not close
this: a job scheduled minutes ago is old when it is promoted. Main's
`10876221e8` now schedules exactly such jobs, a provider backoff of one to three
minutes.

**Fix.** The snapshot reads the tables in the order a job moves through them:
scheduled, blocked, ready, claimed, failed. A move between two reads then always
lands in a table not yet read, so the job is seen at least once.

**Proof.** `QueueExecution.lean`: `old_order_misses_promotion` (scheduled to
ready after the first read), `old_order_unsafe`, and
`flow_order_sees_every_move` (every forward move, after any number of reads).
The model now also carries main's grace: `orphaned` adds the age condition,
`orphaned_sound` keeps soundness, and the conformance fixture covers all 64
combinations of the five flags and the age.

**Specs.** `spec/services/work_engine/reconciler_spec.rb` "does not call an old
job orphaned when it moves ... during the snapshot", for scheduled to ready,
blocked to ready, and ready to claimed, each after every one of the first four
reads. The first two were red before the reorder.

## F119. A reopened Step whose Run never came was invisible to the reconciler — fixed (Lead L13)

**Before.** A retry or a provider backoff reopens a Step that keeps its earlier
attempt's terminal Runs. Until the fresh Run is created, the Step is queued with
only terminal Runs. `queued_step_without_run` required no Runs at all, and
`running_step_with_terminal_runs` skips a Step reopened since its latest Run
(main's `98d30fa654`, so a retry waiting its turn is left alone). The
Workflow-level check counts the queued Step as active. So when the Run was never
created, nothing flagged the Step. That happens when the scheduled
`WorkflowPhaseAdmissionJob` is lost, or when `DeferredPhaseResume` returns
without a Run and without rescheduling ("unowned", "not_ready", a provider
hold). The provider backoff from main's `10876221e8` sends every transient
provider failure down this path. `ResumeQueuedStep` also refused any Step with a
Run, so it could not have repaired one.

**Fix.** `WorkEngine::Reconciler.reopened_awaiting_run_at(step)` returns the
reopen's time when a Step with Runs is waiting for a fresh one: it is awaiting a
Run, every Run is terminal, and the Step or its Workflow was reopened after the
latest Run ended. `queued_step_without_run` accepts such a Step once the usual
grace has passed since the reopen, and `ResumeQueuedStep` re-checks with the
same predicate. The other filters still apply: a Step behind its predecessors,
a deliberate wait, grader admission, or a pending backoff.

**Proof.** `ReopenedStepLiveness.lean`, over every combination of the inputs
both checks read. `before_strands` gives the stranded Step. `after_live`: every
actionable queued Step is flagged. `after_exclusive`: never by both checks.
`resume_agrees`: the repair acts on every Step the check flags for it. All three
methods are in `formal/mirrors.yml`.

**Specs.** `spec/services/work_engine/reconciler_spec.rb`: "flags a reopened Step
whose resume never created its Run" and "resumes a reopened Step whose resume
never created its Run" (both red before the fix), and "waits for a just-reopened
Step's own resume before flagging it".

**Also found.** A third reserving path in NY35's lock cycle surfaced after the
rebase: `BaseRefreshRetryEnqueuer#instantiate_retry!` reserves a provider
account (locking the User row), then writes artifacts on its source Workflow,
which locks it. The simulation `checkpoint_backed_blocked_stack_recovery`
failed with a lock-order error. That path only reserves since main's
`c7b2166fe8` let user-level availability through. It is in `PENDING_DECISION`
with the NY35 group, and NY35's context names it.

## F120. The repair that made main healthy was closed as superseded — fixed (superseded by main's f4caf4f261)

**Before.** Main's `3788b1a9b9` added `supersede_unneeded_preflight_repairs!`: once
main is healthy, any main-branch repair that has not started implementing is
closed as `superseded`. But a repair whose preflight passes is exactly such a
repair, and it is what makes main healthy. `MainBranchRepair.after_success`
records healthy grader and CI results, calls
`MainHealthChangedService.on_health_change!`, and only then closes its own anchor
Job as `preflight_passed`. The health change got there first and closed it as
`superseded`. Three examples in `spec/services/workflows/main_branch_repair_spec.rb`
fail on main because of this. The closure reason is the Job's record of why it
ended, and the reconciler's own completed-repair closure uses `preflight_passed`
for the same case. So a repair that confirmed main healthy read as one that was
merely overtaken.

**Fix.** The sweep skips a repair whose Workflow recorded `preflight_passed`.
That repair closes itself right after, with the right reason. Main fixed the
same bug independently in `f4caf4f261`, in the shared iterator and for
`preflight_inconclusive` too. After the rebase, this branch's narrower skip was
removed in favour of main's.

**Specs.** The three existing `main_branch_repair_spec.rb` examples, red on main
and green with the fix; `main_health_changed_service_spec.rb` unchanged and green.

## F121. A pending Job closure locked a sibling Workflow after the Steps (NY33: A)

**Before.** NY33 described the inversion as "cancelling a Workflow cascades to
its descendants: A, A's Steps, then B". With its pending entry removed, the CI-only
suite in raise mode names the real path in two `auto_merge_spec.rb` examples:

1. Cancelling Workflow A's Run commits.
2. `Workflows::LifecyclePropagation#cancelled!` cancels A's Steps and locks each
   one (`cancel_active_descendants!`).
3. It then calls `JobClosure.apply_pending!`. The closure's `close_now!` cancels
   the Job's other active Workflows, locking sibling Workflow B after A's Steps.

The same shape exists on the succeeded, failed and blocked paths, which lock the
WorkUnit before applying the closure.

**Fix.** `JobClosure.lock_pending_workflows!(workflow)` locks every Workflow the
pending closures will cancel, in id order, and every lifecycle path calls it
first. The cancellations then re-lock rows already held. Siblings are not a
tree, so the operator's "parent first, then descendants by id" becomes "the
cancelling Workflow, then the closure's Workflows by id", the order that is
consistent between any two such transactions.

**What is left.** `cancellation_attribution_spec.rb`'s stacked cascade stubs an
`after_cancel` hook to cancel another Workflow from inside the root's cancel,
after its Steps are locked. No real hook cancels a Workflow directly, and no
other example in the suite reaches this. The pending entry stays, narrowed in
its comment to hook-driven nested cancellation, so a real one would be recorded,
not missed.

**Proof.** `LockOrder.lean`: `closure_cascade_before_inverts` and
`closure_cascade_after_in_order`. `JobClosure.lock_pending_workflows!` and
`LifecyclePropagation#cancelled!` are in `formal/mirrors.yml`.

**Specs.** `spec/services/job_closure_spec.rb` "locks the sibling Workflow before
any Step" asserts that the checker records no violation, so the pending entry
cannot mask a regression. It was red without the pre-lock. The `auto_merge_spec.rb`
examples pass.

## F122. A chat's self-scheduled wakeups are bounded without approval (NY34: B)

**Before.** Main's `11d8bc436c` made `schedule_wakeup` essential, so it never
asks. Each wakeup starts a full, paid agent turn, and that turn could schedule
the next wakeup with no limit on count or chain. A chat could wake itself once a
minute indefinitely, with no approval anywhere.

**Fix.** Each `ChatWakeup` records `chain_depth` and `source_wakeup_id`. A turn
that a wakeup started (its message carries `requested_by: "wakeup"`) links its
follow-up to that wakeup, one level deeper. A human turn starts at depth 1.
`ScheduleWakeupTool#chain_refusal` refuses a second follow-up from the same
wakeup turn. It also refuses once the source wakeup's depth reaches
`AppSetting#wakeup_chain_limit`: the operator chose 100, configurable from
Admin → Settings (range 1–10,000).

The decision says a chain past the limit "asks". The tool is essential, so the
approval gate never sees it. The refusal tells the agent to ask the user in
chat whether to continue, and the user's reply starts a new chain. That is the
ask, without a new pending-action type. A cross-chat message starts a turn whose
message is not a wakeup, so it also starts a new chain; that is not bounded here.

**Proof.** `WakeupChain.lean`. `depth_bounded`: every created wakeup has depth at
most `limit`. `one_child`: a wakeup turn schedules at most one follow-up.
`chain_length_bounded`: the chain from one human turn is at most `limit`
wakeups. `default_chain` checks the limit of 100. `chain_refusal` is in
`formal/mirrors.yml`.

**Specs.** `spec/services/syrus_chat_mcp/schedule_wakeup_tool_spec.rb` "chain
bound" (six examples; the four that need the new logic were red without it).
`AdminSettings.test.tsx` "saves the wakeup chain limit". The settings registry
and admin page fixtures include the new key.

**Docs.** `config/syrus_docs/chat.md`, `app_settings.md`, `permission_authority.md`,
and the website's features page.

## F123. The provider reservation's User lock never waits (NY36: D)

**Before.** `AvailabilitySelector#reserve_least_pressured_account` locked the
User row with `with_lock`, as a mutex, so two reservations for one user see each
other's pins. That lock was taken inside whatever transaction was open, before
or after Workflow, Step and Job locks depending on the caller, and held to
commit: a two-way cycle no position in the order could break (NY31, NY35).
Option A, locking the User first in every reserving transaction, kept finding
new entry points. Main's `3378299a82` then wrote the pin with `update_columns`,
which still takes an InnoDB row lock (Lead L14).

**Fix.** The reservation takes the User row with `FOR UPDATE NOWAIT`
(`reservation_mutex!`). Uncontended, nothing changes: the mutex serializes
reservations. If another transaction holds the row, MySQL fails the statement
at once (`ER_LOCK_NOWAIT`). The reservation then goes ahead without the mutex
and picks from the counts it can see, so the worst case is two reservations
choosing the same account, and only under contention. The checker treats a
NOWAIT lock as outside the order, and the reservation's `PENDING_DECISION` entry
is gone. NY35's partial option-A work is not needed.

**Proof.** `LockOrder.lean`: `nowait_never_waits` (a NOWAIT request adds no
wait-for edge, so it cannot close a cycle whatever else the transaction holds
or locks) and `blocking_request_waits`. `reservation_mutex!` is in
`formal/mirrors.yml`.

**Specs.** `availability_selector_spec.rb` "takes the reservation lock without
waiting" (red before) and "still selects and pins an account when another
reservation holds the User row". `lock_order_spec.rb` "treats a NOWAIT lock as
outside the order" (red before). The reservation paths that needed the pending
entry pass in raise mode: provider admission, retry enqueuer, step dispatcher
and the simulations, 502 examples.

## F124. Starting a Run locked its Job before writing the Run — fixed (NY37: A, part 1)

**Before.** `Run#start` ran `before { job.lock! }` and then saved the Run. The
order puts Run before Job, and an UPDATE holds its row lock to commit, so any
path that started a Run without locking it first wrote a Run while holding its
Job. That was 131 hits in the write-tracking survey (Lead L14).

**Fix.** `start` locks the Run's own row first, with a locking query rather than
`lock!` so the attributes the caller set before `start!` are kept, and then the
Job.

**Specs.** `spec/models/run_spec.rb` "locks the Run before the Job it writes"
(red before; it also checks an unsaved attribute survives). `run_spec.rb` and
`run_job_spec.rb` pass.

**Rest of NY37.** The WorkUnit-last change is written and waits on NY38, because
the WorkIntent the same transitions settle ranks before Workflow. The
Step-then-Workflow and Job-then-Epic groups are not yet traced.

## F125. A finishing Workflow wrote its own row after its Steps (NY37: A, part 2) — held back from main, superseded by NY40

*Held back (2026-11-24).* The full suite before a push to main found that the
own-row lock is itself an inversion under the current order: the success path
then locks the Job in `AutoApprovalRule`, and Job ranks before Workflow. Locking
the Job first inside the transition is no better, because callers such as
`WorkflowCancellation` already hold the Workflow. The right fix is at the
callers' entry points, which is NY40's `Lineage.lock!`. So the change is left
out of the main push, and NY40 replaces it on the branch.


**Before.** `Workflows::LifecyclePropagation`'s terminal methods run inside the
AASM event, before AASM saves the Workflow row. They cancel and write the
Steps (`cancel_active_descendants!` locks each one), and only then is the
Workflow row written. When a caller did not already hold the Workflow, for
example a direct `workflow.cancel!`, the transaction wrote a Workflow while
holding its Steps (Step ranks after Workflow). That was 64 hits in the
write-tracking survey.

**Fix.** Every terminal method (`succeeded!`, `failed!`, `cancelled!`,
`blocked!`) first takes the Workflow's own row with a locking query, which does
not reload, so the transition's unsaved state is kept. A caller that already
holds it re-locks for free. The order is now the cancelling Workflow, then the
pending closure's Workflows by id (F121), then Steps.

**Specs.** `spec/services/workflows/lifecycle_propagation_spec.rb` "locks the
Workflow's row before its Steps when it finishes" (red before). The workflow,
work-unit, step-dispatcher, job-closure, lock-order, Workflow model and
simulation specs pass (1,057 examples).

**Rest of NY37.**

- **WorkUnit last:** written, and waits on NY38 (the WorkIntent's rank).
- **Job, then Epic (23 hits):** a different shape. A Job's state change rolls
  up into its Epic's state (`Job#refresh_epic_auto_state`, an `after_save`)
  inside the same transaction, and the order puts Epic first because merge
  trains lock the Epic before its members. Fixing it means either locking the
  Epic before the Job at every Job transition, which spreads as NY35's A did,
  or running the rollup after commit, which lets a reader briefly see an Epic
  behind its children. Not changed; to be asked.

## F126. The boundary scan missed two dependencies the deletion run catches — fixed (plugin-deletion pilot)

**The pilot.** Can a static check replace `bin/plugin-boundary-audit`'s
20-minute per-plugin deletion run, which boots a reduced copy of the tree?

- `PluginDeletion.lean` states what the run checks as graph closure. Deleting a
  plugin removes it and its transitive dependents, and `closed_of_no_crossing`
  proves for every graph that checking the edges leaving kept nodes is enough.
- `Formal::PluginDeletion` applies that rule to the source boundary audit's
  edges. It agrees with the model on all 1,024 three-node graphs
  (`spec/formal/plugin_deletion_conformance_spec.rb`), and it decides all 65
  bundled plugins from one scan in about 12 seconds.

The value rests on the scan being complete, so the pilot planted one dependency
of each kind from core onto `coworkers` and compared the two checks.

| Planted kind                                  | Scan before | Deletion run | Scan after |
| --------------------------------------------- | ----------- | ------------ | ---------- |
| Ruby constant                                 | caught      | caught       | caught     |
| route to a plugin controller                  | caught      | caught       | caught     |
| frontend import of plugin source              | caught      | caught       | caught     |
| `Rails.root.join("plugins/...")`              | caught      | caught       | caught     |
| `require "coworkers"`                         | **missed**  | caught (LoadError, confirmed on a throwaway branch) | caught |
| `"Coworkers::Coworker".constantize`, `const_get("...")` | **missed** | caught (NameError at load) | caught |
| `"...".safe_constantize`                      | allowed     | survives (returns nil) | allowed |
| bare frontend module-key string               | missed      | survives (imports nothing) | missed |
| foreign key into a plugin table               | missed      | survives (the reduced tree loads the full schema) | missed |

**Fix.** `Admin::PluginSourceBoundaryAudit`, which is also the required
`plugin-boundaries` grader, now flags:

- a `require` of a plugin's library (each manifest's top-level `lib/` names);
- a quoted plugin constant resolved in a way that raises (`.constantize`,
  `const_get("...")`).

`safe_constantize` stays allowed. It is how core and plugins reach optional
plugins on purpose, and the full tree has several such lookups, all
nil-guarded. The whole tree passes the tightened check.

**Result.** On every kind tried, the scan is now at least as strong as the
deletion run. The two kinds neither catches, a module-key string and a schema
foreign key, are runtime and schema couplings the deletion run was never
checking. Next: decide whether the per-plugin removability graders become
nightly audits of the scan, with the scan gating PRs.

**Specs.** `spec/architecture/plugin_source_boundary_audit_spec.rb` "flags a core
require of a plugin library and a plugin constant resolved by name" (red
before; it also pins that `safe_constantize` and a printed name stay allowed).
`spec/services/formal/plugin_deletion_spec.rb`,
`spec/formal/plugin_deletion_conformance_spec.rb`.

## F127. A preserved merge-train relaunch that never ran hid the train from the reconciler forever — fixed

**Before.** Main's `0654328aad` made `WorkEngine::RuntimeOwnership` count a
pending preserved-relaunch `AutoRetryAttempt` as landing work, so the
reconciler stops deferring a preserved train's members during the 30 seconds
before the relaunch. The window had no end. `AutoRetryJob` discards only on
`RecordNotFound`, so any other exception leaves a failed SolidQueue execution
and the attempt pending forever. `prune_stale_pending!` has no "overdue" reason
and the reconciler has no check for an overdue attempt. Such a train's members
then sat in landing with no active work and nothing noticing. Before the
change, the reconciler's orphaned-landing check would at least have deferred
them.

**Fix.** Only an attempt whose `scheduled_at` is within
`PRESERVED_RELAUNCH_GRACE` (15 minutes) counts. A relaunch still pending past
that is treated as lost, and the reconciler's orphaned-landing-slot handling
applies again.

**Specs.** `spec/services/work_engine/runtime_ownership_spec.rb` "stops counting
a relaunch that is long overdue" (red before) and "still counts a relaunch that
is due but within the grace". The engine, merge-train and formal specs pass
(1,470 examples).

## F128. Plugin deletability is decided by the scan, for every plugin (NY42)

**Change.** The required `plugin-boundaries` grader (`bin/check-plugin-boundaries`)
now runs `Formal::PluginDeletion` for every bundled plugin (67 today) and fails
on any plugin whose deletion is not `safe`, naming the edges. That adds a few
seconds. The `coworkers-removability` grader is retired. It booted a reduced
copy of the tree for one plugin only and took about 20 minutes. There is no
nightly audit.

**What replaces the audit.** `spec/architecture/plugin_deletion_plants_spec.rb`
runs in normal CI. It plants one coupling of each known kind from core onto
`coworkers` in a temp tree and pins the verdict:

- `broken`: a plugin constant, `constantize`, `const_get`, a `require` of the
  plugin library, a route, a frontend import, a plugin source path;
- `safe`: `safe_constantize`, a printed name, no coupling;
- known gaps, pinned `safe` and documented: a bare frontend module-key string
  and a schema foreign key into a plugin table. Neither the scan nor the old
  deletion run catches them.

A newly found kind is added as a plant.

**Limit.** The scan skips specs. A core spec that enumerates plugin
contributions is caught only by `bin/plugin-boundary-audit <name>` run with
the suite as its command, which stays available for manual use
(`docs/engineering/conventions/plugins.md`).

**Specs.** The plant spec, plus `spec/bin/plugin_boundary_audit_spec.rb` ("leaves
physical removal to manual use, with the boundary grader deciding
deletability") and `spec/config/syrus_grader_config_spec.rb` (the grader list
without the retired grader). 68 examples pass.

## F129. Hotfix sync and promotion move a landing branch only under its merge lock (NY41: A, part 1)

**Before.** `MergeLock` serializes a landing's last sequence on one branch:
check that the validated base is still the head, then merge. `expected_sha`
guards the PR head, not the base, so this is only sound if nothing else writes
the branch in between. `Steps::HotfixSyncPublish` and `Steps::PromotionPublish`
did write landing branches without it, in both their modes:

- a direct push, whose lease only guards against overwriting;
- a PR auto-merge.

Promotion writes `main`, the branch every default-branch lane merges into
(Lead L15).

**Fix.** Both writes in both steps hold the merge lock of the branch they write
(`with_target_merge_lock`), keyed by `WorkDefinitions.merge_lock_key_for_branch`,
which has the same shape as the landing key. `MergeLockControl` gets an
overridable `merge_lock_key`, and the two step kinds join `MergeLock`'s
first-come waiter list. A lock still held when the wait runs out fails the
step with a message saying why. Manual-PR mode, which never merges, takes no
lock.

**Proof.** `MergeExclusion.lean`:

- `no_write_between_check_and_merge`: with every writer locked, no valid trace
  of up to five events, for two lanes and a publisher, puts another write
  between a lane's check and its merge.
- `unlocked_writer_breaks_it`: one unlocked publisher does.

`MergeLock#try_acquire` and both steps' `with_target_merge_lock` are in
`formal/mirrors.yml`.

**Specs.** `hotfix_sync_publish_spec.rb` and `promotion_publish_spec.rb`, "merge
lock on the target branch": a step does not publish while a landing holds the
lock, and holds then releases the lock around its own publish. Red before the
change. Both specs now launch the Workflow through `WorkUnits::Launcher`, as
the dispatchers do in production, so it has the WorkUnit the lock is held on.

**Not yet.** Emergency landing (`EmergencyLand::Lander#merge!`) has no WorkUnit,
and a `WorkUnitLock` requires one. How it should hold the lock is NY43.

## F130. Groundwork for the hierarchical lock order (NY40: A, part 0)

NY40 moves the row-lock order to the hierarchy: AppSetting, User, Epic, Job,
WorkIntent, WorkUnit, Workflow, Step, Run, parents before children. The
rollups that write up the tree stay atomic, because each transaction that can
change a Workflow's state first locks the ancestry with `Lineage.lock!`. The
suite must stay green throughout, so the change is staged:

1. **Target order (this entry).** `Syrus::LockOrder.target` selects which order
   the checker evaluates. It is `:current` by default (still enforced) and
   `:hierarchical` via `SYRUS_LOCK_ORDER_TARGET=hierarchical` or in a spec, so
   progress can be surveyed without failing the suite.
2. **`Lineage.lock!(record)` (this entry).** It locks a Run's, Step's,
   Workflow's, WorkUnit's or Job's ancestry top-down with locking queries,
   never `lock!`, so the caller's unsaved changes are kept.
3. **Next.** Convert the funnels the survey found (about 15 production entry
   points), largest first: `RunJob`'s claim, then the after-commit state
   callbacks, `TerminalWorkflowSync`, the reconciler and repair executor,
   `JobClosure`, `WorkflowCancellation` and the dispatcher. Then flip the
   enforced order, switch write tracking to raise, and update `LockOrder.lean`
   and the docs.

**Progress.** Part 1 converted `RunJob`'s claim and `Run#start`. Part 2
converted `WorkflowCancellation.cancel!` and `WorkUnit#mark_terminal!`, which
now take their ancestry first. It also made a terminal Workflow's descendant
cleanup lock its Steps before any Run. Specs:
`spec/services/lineage_funnels_spec.rb`, raising on the hierarchical order.
Part 3 converted `TerminalWorkflowSync`, `WorkUnit#preempt!`,
`Job#close_with_reason!` (Epic before Job), and the repair executor's
closed-Job cancel, superseded-CI-repair cancel, queued-Run relaunch and
merge-train member close. Part 4 added `Lineage.lock_all!` for several
ancestries at once, possibly across Jobs: every row of a model before any row
of the next model down. `LockOrder.lean` proves every sequence it can take is
in the hierarchical order (`lock_all_in_order`). `JobClosure.lock_pending_workflows!`
uses it, so the sibling cascade no longer inverts
(`closure_lineage_before_inverts`, `closure_lineage_after_in_order`).
`TerminalLockCleanup`, the repair executor's workflow start and
`StepDispatcher.create_run_and_enqueue` also take their ancestry first.
Remaining: the callers that write Steps or the Workflow before creating a Run
(`enqueue_next_loop_iteration!`, `enqueue_try_failure_branch!` and the
parallel grader admission), and Run-before-Step writes in a Run's own
cancellation.

**Specs.** `spec/services/lineage_spec.rb`, in the hierarchical target with
writes tracked and raising: a Run's rollup to its Step, Workflow, WorkUnit and
Job is in order after `Lineage.lock!`, and the same writes without it raise. It
also checks that the helper names the full ancestry and keeps unsaved changes.

---

## F131. The coworker tool surface depended on enablement when first built — fixed

**Invariant.** A value the process memoizes is a function of static inputs
only. `McpToolRegistry.entries_for_surface` builds each surface once per
process. A change on main switched `coworker_entries` to
`ChatToolParity.participants(enabled_only: true)`, which is runtime plugin
enablement. The coworker surface then depended on whether the coworkers plugin
was enabled and healthy at the moment the registry was first built.

**Counterexample.** If the registry is first built while coworkers is
disabled, no coworker parity exceptions apply. The coworker surface then keeps
the Local Mode, coding-workspace and runtime tools (`create_coding_job`,
`run_command`, `write_file`, the `runtime_*` family and others) for the rest of
the process, even after the plugin is enabled. The suite reached that state in
whichever process built the registry first, so `spec/docs/surface_catalogs_spec.rb`
and a coworkers lifecycle-tools spec failed depending on order. The generated
MCP catalog had been refreshed in such a process, so the agent-searchable docs
listed 38 tools on the coworker surface that it does not offer.

**Fix.** `coworker_entries` uses the installed participants again, which are
static per process. Runtime enablement stays where that change also put it:
`Mcp::Sidecar` and `ChatToolParity.extension_context?`, which run per request.
The catalog is regenerated.

**Spec.** `plugins/coworkers/spec/services/coworkers/chat_parity_spec.rb`
rebuilds the registry memo with the plugin enabled and then disabled, and
expects the same coworker surface without the Local Mode tools. It fails
without the fix.

---

## F132. A worker cache holder that outlived its lease released the next holder's — fixed

**Invariant.** `RuntimeImages::WorkerCache` documents that an acquired image
is never removed: eviction claims only an unleased entry. The lease is one row
with a holder count and an expiry, and acquiring an expired lease starts it
over at one holder, so a crashed holder cannot pin an entry forever.

**Counterexample.** A container run held its lease longer than
`lease_seconds` (an hour by default; the container execution backend holds it
for the whole run). Another acquisition then started the lease over at one
holder. When the first run finished, `release` counted the lease down
anyway, to zero, and cleared it. The entry was then evictable while the second
holder was using it. `docker image rm` refuses an image a running container
uses, so the exposure is the time before and between containers in one
acquisition, but the documented guarantee did not hold.
`CacheLease.lean`: `stale_release_unprotects`.

**Fix.** Each started-over lease begins a new `lease_epoch`. A holder records
the epoch it joined, and `release` counts down only a lease of that epoch.
`CacheLease.lean` proves the count then always equals the live holders of the
current epoch (`count_eq_current`), so a live lease with a current holder is
never evictable (`current_holder_protected`).

**Spec.** `spec/services/runtime_images/worker_cache_spec.rb`, "does not let a
holder whose lease expired release a later holder's fresh lease", fails
without the fix.

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

**Resolved (NY15: disable them with an explanation).**
`ChatShellCommandExecutor::Coding#policy_error_code` returns
`containment_required` while `contained_chat_execution` is `required`. The
endpoint then answers 403 with that code and a translated explanation, which
the composer shows as its notice, and queues nothing. `run!` refuses a command
queued before the setting changed, without starting a process. Local Mode is
unaffected. Specs: `chat_shell_commands_spec.rb` "when contained chat
execution is required", and `coding_spec.rb` `#policy_error_code` and
"#run! under required containment". The website and `config/syrus_docs`
describe it.

`providers_for`'s own database-error fallback hands out disabled backends too.
That is the NY13 question again, not a separate one.

---

## M15. Purge removes only plugin-owned tables — audited, schema drift found

DOC-44 plugin host: "Purge removes only resources declared as plugin-owned and
preserves generic history and evidence."

**The rule holds by construction.** `Syrus::PluginPurge#tables` keeps a table
only when the plugin's own models or migrations declare it *and* its name
carries the plugin's prefix (the namespace grader's rule). Shared tables are
touched only through the plugin's `config/plugin_ownership.yml`
`inline_fields`, which name exact columns and a row predicate. A Lean model
would restate that definition, so the evidence is an audit of the bundled set
(57 plugins, 60 purgeable tables, against the live development schema):

- No two plugins' purge sets share a table.
- Every live table with a plugin's prefix is in that plugin's purge set, apart
  from the two orphans below. No purge set names a table nobody declares.
- `scheduled_tasks`, `connected_accounts_*` and `github_source_issues` were
  created by core migrations before their plugins were extracted. Their models
  now live in the plugin, so the plugin owning them is right.
- The ownership manifests' `tables:` lists agree with the computed purge sets.
- Generic history survives: purge deletes no Job, Workflow, Run or evidence
  row. The one shared-row predicate (Coworkers' `scheduled_tasks` rows with a
  `coworker_id`) removes rows of a plugin-owned table.

**Drift found.** `db/schema.rb` declares `operator_briefing_review_findings`
and `operator_briefing_workflow_notable_changes`, and no migration creates
them. The detector pipeline that used them was removed by *editing* the
plugin's original migration, not by adding a drop migration. A later schema
dump copied the tables back from a database that still had them. So:

- `db:schema:load` builds both on every fresh install;
- databases that ran the original migration keep them;
- purging `operator_briefing` can never remove them.

No code reads them and they carry no foreign keys, so they are inert.

**Pinned.** `spec/architecture/schema_tables_have_migrations_spec.rb`: every
`schema.rb` table is created by a core or plugin migration, through a rename
or one of the Solid Queue, Cache and Cable engine schemas. The two orphans are
listed as pending, and a second example fails once either is dropped or gains
a migration. Whether to drop them is NY16.

**Resolved (NY16: delete them).** `DropOrphanedOperatorBriefingTables`
(`plugins/operator_briefing/db/migrate/20261121172512_*`) drops both tables
with `if_exists: true`, so fresh installs that never had them are a no-op. Its
`down` is intentionally empty. They are removed from `schema.rb`, and the
architecture spec no longer carries a pending list: every table must have a
creating migration. `drop_orphaned_operator_briefing_tables_spec.rb` covers
the drop, a second run, and that the plugin's other tables survive.

---

## M16. Every automatic repair has an executor — audited, one dead executor removed

DOC-44 reconciler and plugin host: "Every automatic repair action has an
executor," "Operator-only repairs never become automatic through a missing
policy," and "Plugin repair actions have executors."

- **Automatic actions have policies.** `RepairPlanner` names all 63 of its
  `automatic_plan` actions as literals, and every one has a
  `RepairExecutor::Policies` class. Before this, `Policies::Default` would only
  record "no executor policy exists", so an automatic plan without a policy
  would have been planned and skipped on every pass.
- **A missing planner policy stays manual.** An issue kind with no planner
  policy gets `operator_plan("operator_review_recovery")`, never an automatic
  plan, even when the issue is flagged safe to auto-repair.
- **No plugin repair actions exist.** Plugins contribute no reconciler issue
  kinds or repair policies. Their problem kinds carry a `default_remediation`
  from the closed set. `RetryFailedStepEnqueuer` executes only `rebuild_unit`
  and `resume_step`, and answers every other remediation with an explicit
  "requires a new workflow attempt", so no remediation reaches a missing
  executor.

**Dead executor.** `Policies::DeferLandingStartBlockedWorkflow` had been
unreachable since landing start blocks moved to `start_workflow`. No planner
emitted it, and the executor is called only on freshly planned results. It
still carried authority to fail a landing workflow and send its Job back to
`approved`, so it is removed rather than left for whatever next names it.

**Pinned.** `spec/architecture/repair_action_executors_spec.rb`:

- every automatic action is a literal and has a policy;
- every policy is planned automatically somewhere (this failed for the dead
  executor);
- an unknown issue kind flagged safe still gets a non-automatic operator plan.

---

## M17. Migrations before enablement, and plugin-set admission — audited, one question

DOC-44 plugin host: "Required migrations and schema are present before
enablement becomes active," and "Work requiring plugin-set digest D is never
admitted to a process or worker observing a different incompatible digest."

**Migrations hold by construction.** Every installed plugin's `db/migrate` is
on `config.paths["db/migrate"]`, whether or not the plugin is enabled
(`config/application.rb`). The deploy runs migrations as a one-shot Job from
the new image before any workload moves (`Deploy::Migrations`). That Job copies
the web pod's volumes, so externally mounted plugins are migrated too.
Enablement is a `PluginRecord` flag and never runs or needs a migration, so a
plugin's schema is present before it can be switched on. The one way around
this is an external plugin added to a mounted plugin path between deploys,
whose process then boots without a migrate step. That is a deployment
precondition, not a host rule.

**Plugin-set admission is not enforced.** Workers report
`SYRUS_PLUGIN_SET_DIGEST` and their plugin list in `InstanceVersion`
heartbeats. `PluginDesiredState::Convergence` uses them only for the admin
convergence view: `converged`, `pending_restart`, `behind`. No Run, Step or
Workflow records the plugin set it needs, and `RunQueueResolver` routes only
by OS and toolchain capabilities. So during a fleet plugin rollout (`pending_restart`),
or for a fleet installation limited to some process roles, a worker without
the plugin can claim a Run whose step kind only that plugin provides.
`Steps.handler_for` then raises in `RunJob`, and `handle_failure` fails the
step terminally, instead of leaving it for a worker that has the plugin. The
F61 and NY14 cancellation path applies after that. This affects only fleet
installations of external plugins: bundled plugins load on every process and
declare no roles. That is NY17.

---

## M18. Entity store revision merge — proved, convergence relies on refetch

DOC-44 Phase 5: "Accepted entity revisions never decrease," "the higher
revision wins regardless of arrival order," "an older REST response cannot
overwrite a newer cable patch," and "equal-revision overlapping patches are
equal or have deterministic precedence."

`EntityMerge.lean` models `upsertEntity` over every order of up to three
writes, with revisions 0 to 2, each setting any subset of two fields.

- **Proved.** The stored revision never decreases (`monotone`). Full writes
  with distinct revisions end in the same state in every order
  (`full_writes_commute`), so an older snapshot never overwrites a newer
  patch.
- **Units agree.** Every snapshot source of an entity kind that cable events
  patch with fields (jobs, workflows, steps, runs, chat messages) carries
  `entity_revision`. Each event's `revision` is the counter of the record it
  names: the job-level event uses the Job's counter, and the per-resource
  event uses the record's own. So the `updated_at` fallback in
  `revisionFromFields`, a millisecond timestamp, never meets an integer
  revision. If it did, it would freeze the entity, because every later
  integer revision would compare as older. No payload of these kinds uses a
  bare `revision` key, which `revisionFromFields` would read first.
- **Not guaranteed; Syrus relies on refetch.** A partial patch at revision
  N+1 keeps the fields it did not carry from revision N and labels them N+1
  (`partial_patch_relabels`). Two writes at the same revision resolve by
  arrival order. `JobEventFields` carries `start_blocked_*`, which is derived
  from WorkUnits and changes without the Job's revision moving, so a job
  detail snapshot already in flight can briefly restore an older blocked
  reason. Both converge: every job-level event also invalidates the job
  queries, and the refetch it triggers is a newer full snapshot. No change
  made.

---

## M19. Subscriptions, optimistic acknowledgement, hidden tabs, reconnect — audited, no bug

The rest of DOC-44 Phase 5's frontend invariants, read against
`app/frontend/lib/actionCable.ts`, `appEvents.ts` and
`routes/chat/inFlightComposerDraftStore.ts`.

- **Subscription changes.** "An old resource event cannot mutate the newly
  selected route." This holds. Job and Chat subscriptions pass every event to
  `applyAppEvent`, which keys every write on the event's own identifiers:
  entity store by `(kind, id)`, chat tails by `["chats", event.id]`, and job
  patches by `event.job_id`. Nothing writes to "the current route", so a late
  event for the chat being left can change only that chat's cache.
- **Optimistic acknowledgement.** "Client idempotency keys acknowledge exactly
  the intended optimistic item." This holds.
  `acknowledgeInFlightComposerDraft` matches the chat id *and* the key, so a
  delivery for one chat never acknowledges another chat's draft.
- **Hidden tabs.** "Hidden-tab invalidations eventually refetch after
  visibility returns." This holds. While hidden, `invalidateAppQuery` marks the
  query stale without fetching and records it in `hiddenInvalidations`. The
  first `visibilitychange` to visible refetches every recorded active target.
  Inactive ones are already stale and refetch when they mount.
- **Reconnect recovery.** "Reconnect recovery covers every query that could
  have missed state." This holds, with bounded staleness.
  `recoverAppEventContinuity` refetches the *active* continuity queries, and
  the Job and Chat channels recover their own resource on reconnect. An
  inactive cached query is not invalidated by the sweep, so if it is mounted
  again within its `staleTime` it shows data from before the disconnect. Every
  continuity query uses the 30 s default or shorter; the `Infinity` stale
  times belong to settings, themes, admin controls and immutable per-node
  data. So that window is at most 30 s.

The global-gap convergence question remains NY19, and Job subscription
revocation NY20.

---

## M20. Backup retention never deletes what it must keep — audited, one question

Main's backup epic ("Recheck backup deletion gates atomically," "Fence backup
replication attempts with leases," "Preserve verified backup replications").
The invariants it relies on, read against `LocalBackups::Retention` and
`LocalBackups::ArtifactSource`:

- **Safety holds.** Retention never deletes the protected backup (the newest
  valid one, or the newest completed one when none is valid), a pinned backup,
  one with an uploading replication, or, when verified replication is
  required, one without a verified copy. `claim_deletions!` re-evaluates every
  gate inside one transaction, from `Backup.lock` and `Replication.lock` rows,
  and moves the claimed rows to `deleting` before any file is touched. Pinning
  and verification changes take the same Backup row lock, so they serialize
  with the claim.
- **Replication cannot race a deletion.** `ArtifactSource.pin` locks the
  Backup row and requires it to be `completed`. A pin after the claim finds
  `deleting` and fails. A pin before it makes the claim skip the backup.
- **A verified copy is never overwritten.** `pin` refuses a verified
  replication. `record_replication` and `release_pin` require the current
  lease token on an uploading row, so a stale attempt that has been taken over
  cannot record anything.
- **Failure restores state.** A failed filesystem delete returns the claimed
  rows to `completed`.

**Liveness question.** The lease lasts six hours and is never renewed. Nothing
expires it, and retention treats any `uploading` replication as protected,
lease expired or not. While the destination keeps retrying, it re-pins after
expiry and the state resolves. If the destination never retries, for example
because it was removed while an upload was in flight, that backup is
protected forever, and capacity reclamation cannot free it. Making expiry
lift the protection would let retention delete an artifact under an upload
running longer than six hours. That is NY21.

---

## M21. Recovery preflight blocks known incompatibility, warns on unknowns — audited, one question

Main's "Block unknown plugin versions in recovery" and the preflight checks in
`LocalBackups::Recovery` (`plugins/local_backups/lib/local_backups/recovery.rb`).

- **Plugins: holds.** Every plugin the bundle marks as required must be
  present. When the bundle names a version, the destination must report
  exactly that version, and a destination plugin with no version is
  "unknown" and blocks.
- **Known mismatches fail.** These block the restore: a different database
  adapter, a different database major version, a destination application
  older than the bundle's, or a destination outside a declared compatibility
  list.
- **Unknowns only warn.** These are all `warn`, and preflight reports
  `ready` whenever nothing *failed*, with no acknowledgement required:
  - the destination's application version, database adapter or database
    version was not supplied;
  - the bundle declares no compatibility range;
  - the application versions do not parse as versions (development builds,
    SHAs).

  So a restore can proceed into a destination whose compatibility was never
  established. That is NY22.

---

## M23. CLI mutation confirmation and checkout safety — audited, one design question

**Scope.** DOC-44 Phase 6, Syrus CLI: "Mutations are confirmed, single and
target what was shown", and "Checkout never destroys local work".

**Confirmation holds.**

- `job create` and `epic create` prompt with the repository they will target,
  and anything but `y`/`yes` (EOF included) cancels.
- The repository ID sent is the one whose slug exactly equals the slug shown
  (`cliplugin.RepositoryIDForSlug`), so the prompt and the request cannot
  disagree.
- The API client never retries a request, so one confirmation produces at most
  one mutation.
- The remaining mutating commands (`approve`, `cancel`, `retry`, ...) take an
  explicit ID and are authorized server-side, which is the CLI's convention.

**Checkout holds.**

- *Job and Epic branches (`checkoutJobBranch`).* The current branch is refused
  if it has any local changes, untracked files included, before
  `reset --hard`. A local branch that is not an ancestor of origin is copied to
  `syrus/backup/<branch>-<timestamp>` before `reset --hard` or `branch -f`. A
  backup-name collision fails the command rather than overwriting. A branch
  checked out in another worktree makes `branch -f` fail.
- *Plain branches.* A dirty worktree is refused, and divergence is only ever
  fast-forwarded (`merge --ff-only`).
- *Ordering.* `--complete` fetches every Epic branch before the
  origin-matches-repository check. This only rewrites remote-tracking refs, so
  nothing local is lost.

**Open: post-checkout hooks run branch-authored commands (NY23).** After a Job
or Epic checkout, `runPostCheckoutHooks` runs every `hooks.post_checkout`
command from the `.syrus.yml` files in the *checked-out branch*, with no
prompt, unless `--no-hooks` is passed. Two concerns follow:

- *Who writes that file.* The only gate is `Job.kind != "external_pr"`. For
  every other kind, the branch was written by an agent working from issue
  text. On a repository that accepts outside issues, the issue author can steer
  the agent into adding a hook, and that hook then runs on the reviewer's
  machine during `syrus checkout`, before anyone has read the diff.
- *How the gate is shaped.* It is a deny-list over an open, plugin-extensible
  kind set, so a new kind carrying outside content, or a response without a
  `kind`, runs hooks by default.

---

## Lead L8: a CI-failure repair lost to lock waits on a landing Job (see Lead L2)

**Production (read-only, 11-22, 17:10–17:12 UTC).** Job 9748 (a cron Job, in
`landing`) got a `ci_failure` Workflow (66262) at 17:10:22.

- Its Prepare failed three times in two minutes on
  `ActiveRecord::LockWaitTimeout`. The waits were about 35–45 s each, the
  failures were classified `timeout` (retryable), and the Workflow failed
  without ever starting its first Step.
- Seconds later the landing queue launched `auto_merge` (Workflow 66267) for
  the same Job.

The landing is not unsafe: auto-merge runs its own mergeability preflight and
graders before merging. But the CI repair is lost, and nothing records who
held the lock. Step failures do not reach `backend_exception_events`, and the
Run logs carry no backtrace.

The likely holder is the landing path working on the same Job row while it
prepared the auto-merge. That is the same shape as Lead L2's hot rows, and as
F96's long finish transaction (F96 is not deployed).

**Next step if it recurs.** Record the waiting statement and the lock holder
(`performance_schema.data_lock_waits`, or a backtrace on the Run) before
changing anything.

---

## Lead L7: workspace recovery requeues stranded Runs away from the worker it rebuilt on

Coverage item `workspace-missing` (storage loss). Production evidence is not
checked: searching Run logs is too expensive for the read-only connection.

`WorkflowWorkspaceRecovery` handles a missing workspace in three states:

1. `Reconstruct` rebuilds the workspace on the current worker from a durable
   source and records that worker as the Workflow's storage owner
   (`WorkflowWorkspaceLifecycle.record_identity!`).
2. `Resume` either refuses, returning `retry_required` when a mutating Run is
   still marked running, or requeues every non-live active Run through
   `Run#reenqueue!(ignore_workflow_affinity: true)`.
3. With that flag, `RunQueueResolver#compatible_resume_queue` returns `nil`.
   The Run goes to the general queue, not to the storage-specific resume
   queue of the worker that holds the rebuilt workspace.

The flag escapes the *lost* worker's affinity. By the time Resume runs,
`record_identity!` has already replaced that affinity with the live
rebuilding worker, so honouring it would route the Run where the workspace
is. As written, any worker may claim the Run. One without the workspace finds
it missing and rebuilds again.

That converges, because every worker can rebuild from durable sources, but it
can repeat a rebuild for nothing and stretches the window in which recovery
can fail. The proof obligation for the item is still that recovery leaves no
Run pinned to the lost storage key. On this reading that holds: requeued Runs
are unpinned, and an unrequeued running mutation returns `retry_required` to
the caller. It is not yet modelled.

---

## Lead L9: order-dependent failures on main's rspec-ci shards after the 11-22 push

Two main graders failed with examples that pass locally in every order tried:

- Main grader 66311 failed on `installer_spec.rb`, "disposes experimental
  plugin effects when the instance opts out". The log showed an extra
  `:install` after beta mode was turned off.
- Main grader 66315 failed on these examples:
  - this branch's F93 example in `capability_registry_spec.rb`;
  - two `jobs_spec.rb` / `job_detail_payload_spec.rb` examples, with
    "Validation failed: Enabled requires beta mode for beta or experimental
    features";
  - two `spec/syrus/spec_support/bundled_plugins_spec.rb` examples, where the
    suite's beta-mode baseline helper read the opposite value.

**What was ruled out locally.** Spec order within one process: those files,
together with this branch's capability spec, pass in six random orders. The
beta-mode memo is per `Current` and is cleared by an `after_save` hook on
`AppSetting`, which the helper's `update!` triggers.

**Fixed here.** The F93 example stubbed the enablement read after `register`
had cached the records. It now clears the plugin-record cache first, as the
neighbouring NY13 example does.

**Hypothesis, not confirmed.** Every other failure involves a *global* row:
the `AppSetting` singleton's beta-mode flag, or plugin enablement records.
That fits separate processes sharing one test database more than it fits
in-process ordering. Main fixed one instance of that class on 11-21 ("Keep
parallel RSpec preflight graders on their own test databases"), and the
11-22 grader placement changes (declared memory reservations, preflight
lanes) change which graders share a host. Runs do not record their worker
host, so the theory needs the grader logs' host lines, or a test database
name per process, to confirm or refute.

**Update: deterministic in CI, not reproducible locally.**

- *In CI:* the merge train for Job 9783 failed all four `rspec-ci` shards on
  each of six fix-loop iterations, with the same examples every time. These
  were the beta-mode ones ("Enabled requires beta mode", a 422 enabling a
  plugin, the beta baseline helper reading the opposite value) plus the F93
  example. So it is not flaky.
- *Locally:* every `ci_only` example in the suite, run in one process (5,304
  examples), gives **0 failures**.

So neither in-process order nor running everything together reproduces it,
and the difference is in the grader's environment. The multi-process theory
above is weaker now: each shard's CI-only phase is a single process.

**New hypothesis, unverified (no access to grader workers):** stale rows in a
reused test database.

- Graders reuse a worker-local prepared dependency layer.
- `bin/rspec-ci` runs `bin/rails db:test:prepare`, which rebuilds the main
  test database. The parallel workers' databases are prepared separately.
- If those SQLite files survive inside a reused layer or checkout, a leftover
  `AppSetting` beta-mode row would contradict the suite baseline in every run
  on that worker. That would make it deterministic per worker and absent
  locally.

**To confirm:** list `db/*.sqlite3` in a grader's immutable checkout before
the run, or log `AppSetting.count` / `beta_mode_enabled` at suite start.

---

## M84. Main through `6edc2c7761`

A job bundle, mostly frontend touch handling, dead-code removal, dependency
refreshes, bounded Test Insights reads and architecture docs. Two commits
change behaviour the branch relies on:

- **"Reuse live instance lookups during RunJob admission"** (`7065dda1b7`).
  `RunQueueResolver` reads fresh worker instances once per resolver run, keyed
  by hostname. *Relied-on invariant:* admission sees the same live workers as
  before. Holds for the per-host lookup: the old `.first` already ordered by
  primary key, and the lowest id per hostname matches it. One change for the
  worker list: it now holds one instance per hostname, the oldest, where it
  used to hold every fresh row. Just after a worker restarts, while both its
  old and new rows are still fresh, admission sees the old row's capabilities
  until that row's heartbeat lapses. That is transient, so it is recorded and
  not fixed.
- **"Replace policy case switch in MCP sidecar with predicate table"**
  (`45501465c8`). *Relied-on invariant:* the same definitions are chosen for
  every policy. Holds: the branches are unchanged, and the participant list,
  a pure call, is now computed once instead of once per definition.

The refreshed gems needed `bundle install` before the specs would boot. After
the rebase, the resolver, formal, architecture and lock-order specs pass
(1,079 examples).

## M83. Main through `d27d3490ae`

A merge train for the Achievements Epic: a new `achievements` plugin with a
definition registry, unlock persistence, evaluation from domain events,
acknowledgments, a collection page and a development workbench.
*Relied-on invariant:* a plugin reacting to engine events can never fail an
engine transition. Holds:

- It subscribes only to `job.closed` and `epic.upserted`, both `:async` in
  `Syrus::Events`, so evaluation never runs inside the publishing transaction.
  Even `:inline` delivery is isolated: a raising subscriber is logged, not
  propagated.
- A failed evaluation is handed to a plugin-owned retry job (evaluation is
  idempotent), so a failure does not lose the unlock either.

Checked after the rebase: mirrors match, boundaries are clean, the plugin's
specs and the formal specs pass (824 examples), and
`Formal::PluginDeletion.call("achievements")` is `safe`. This is the
plugin-deletion pilot's first look at a newly added plugin.

## M82. Main through `519fe10b07`

- **"Relaunch a preserved merge train even when its failure asks for a
  restart"** (`261caf0860`). A preserved attempt now always relaunches its own
  failed step, instead of taking the fresh-workflow branch that landing Jobs
  never qualify for. *Relied-on invariant:* the relaunch actually runs while
  the train's members wait. Holds, and F127's 15-minute grace still bounds the
  wait if it does not.
- **"Classify a missing table or column as retryable schema version skew"**
  (`5ac7ad0015`). *Relied-on invariant:* the retry is bounded even when the
  missing column is a real bug on the current release, not skew. Holds: a
  retryable classification goes through
  `retry_step_after_infrastructure_failure!`, which checks
  `INFRASTRUCTURE_STEP_RETRY_LIMIT` first (`CascadeReplay.lean`,
  `replay_terminates`). "Reject in-place table and column renames in new
  migrations" (`9c345f1a4b`) narrows how often real skew happens.
- **"Let an accepted landing failure cover the main-grading contract too"**
  (`2486957531`). An accepted test failure now covers its CI-phase target, as
  `target_blockers` already did. *Relied-on invariant:* the acceptance is still
  bound to the exact graded head. Holds: it is the same accepted target, with
  M79's exact-head SHA and fingerprint binding.
- The rest change the commits-behind count (now against the live base), merge
  train patch ids, the reason a bundle is not forming, visual-review error
  text, spec isolation, and schema-dump guidance.

The affected specs pass after the rebase (1,257 examples).

## M81. Main through `97961c9fe5`

A job bundle: plugins routed through `Syrus::Host` facades, interactive chat
tool parity with reviewed exceptions, grace and episode-aware plugin fleet
convergence alerts, a nil provider-account fix in provider selection, paused
Jobs excluded from the review workspace, and ERB-safe migration database
config.

- **"Fix CI: conformance spec grace period, repair closure order, formal
  mirrors"** (`c39aba0944`). These are main's own fixes for issues this branch
  fixed independently: the orphaned-job conformance snapshot needs an old
  timestamp, as F118's age dimension already supplies, and the main-branch
  repair's closure order, as in F120. Main now closes the anchor Job before the
  health change, and the plugin's preflight skip is kept. The rebase is clean.
- **Nil provider account in `AvailabilitySelector`** (`2f6a29a8f1`,
  `cf3ac0c178`, `7df73dff9c`). *Relied-on invariant:* account-less selection
  still serializes reservations where there is an account. Holds alongside
  F123's NOWAIT reservation: the provider-routing and phase-admission specs pass.
- **Host facades** (`b304a6b7c5`, `178ec6cb04`, `4e244c0da4`). *Relied-on
  invariant:* plugins reach core only through `Syrus::Host`. Holds:
  `bin/check-plugin-boundaries` is clean, including F126's require and
  constant-resolution rules.
- The rest (chat tool parity, fleet convergence alerts, coworker
  background-run claims, migration ERB) is covered by the formal and
  architecture specs, which pass (1,169 examples with the provider specs). I
  did not trace it further.

## M80. Main through `feddc2afec`

A merge train for the main-branch health Epic. Main-branch health checking
and repair move from core into the `main_branch_health` plugin, with their
storage in plugin-owned tables. Core gains generic extension points that
plugins fill (work gates, alerts, repair classifiers, work policy), and the
Health tab and dashboard banner come from the plugin. *Relied-on invariants:*

- **Gating and repair behaviour survive the move.** Holds: `formal/mirrors.yml`
  still matches every mirrored method, and the plugin's own 438 specs pass,
  `main_branch_repair_spec.rb` included.
- **F120's fix moved with its service.** Holds: the preflight-repair sweep
  still skips a repair whose Workflow recorded `preflight_passed` or
  `preflight_inconclusive`, now in
  `plugins/main_branch_health/app/services/main_health_changed_service.rb`.
- **Core no longer depends on the plugin.** Holds:
  `bin/check-plugin-boundaries` is clean, including F126's new require and
  constant-resolution rules.

The formal, architecture, work-engine, work-unit and lock-order specs pass
after the rebase (1,901 examples). A first run showed 1,529 failures from a
test database that lacked the Epic's new plugin tables; it was green once
`db:test:prepare` rebuilt the database.

## M79. Main through `0654328aad`

- **"Keep members approved when a preserved merge train cannot relaunch"**
  (`0654328aad`). *Relied-on invariant:* a pending preserved relaunch will run.
  Counterexample: an `AutoRetryJob` that raises leaves it pending forever.
  Fixed as F127. Teardown deferring members, keeping their approval instead of
  failing them, holds: it only follows a preservation decision, which means no
  member was blamed.
- **"Let an adjudicated grader failure leave landing evidence the gate
  honours"** (`c3c430cf1a`). *Relied-on invariant:* an accepted failure is
  evidence only for the exact head it was graded on. Holds: the target carries
  its adjudicator and the gate applies the same exact-head SHA and fingerprint
  binding as a pass. Main updated `ValidationGate.lean` to prove an unaccepted
  failure never passes.
- **"Only call a failing test flaky when it flipped on the same commit"**
  (`d0fb59c0cf`). This narrows `KnownFlakyFailure`: a test counts as flaky only
  if it both passed and failed on one head SHA, and providers that cannot say
  decline. It only removes acceptances, so it cannot let a failure through.
- **"Classify a required MCP tool call that failed in the sidecar as
  infrastructure"** (`0a8cf1c7db`). This applies only when the Run's own MCP
  usage shows the tool was called and never completed. *Relied-on invariant:*
  the reclassified failure still retries a bounded number of times. Holds: it
  is retryable infrastructure, capped by `INFRASTRUCTURE_STEP_RETRY_LIMIT`
  (`CascadeReplay.lean`, `replay_terminates`).
- **"Bound MySQL socket operations on the macOS worker"** (`f61402d29c`).
  Optional connect, read and write timeouts, set only by `bin/macos-worker`.
  Worker configuration.

## M78. Main through `cb9c48211b`

A job bundle of mobile Review work: swipe-intent locking, gesture arbitration,
scroll preservation, and an evidence-based decision brief. Two commits change
what counts as current review evidence:

- **"Only present review evidence for the current implementation head"**
  (`99ea331305`) and **"Resolve current review head with a bounded query set"**
  (`34d3e23e16`). `ReviewWorkspacePlugin::CurrentHead` takes the head recorded
  by the newest succeeded `implement` or `respond` step across the Job's
  Workflows (newest Workflow first, at most 50 candidates). *Relied-on
  invariant:* the workspace calls the same evidence current that the
  required-review barrier enforces. Holds: it uses the barrier's own
  `MUTATION_KINDS`, and `ImmutableReviewHeadBarrier.reviewed_head_sha` stamps
  reviews against the same step's head (per Workflow; the workspace takes the
  newest Workflow that has one). Display only; the barrier is unchanged.

## M77. Main through `95e61b9291`

A merge train for the parallel landing lanes Epic.

- **"Serialize the final merge behind a per-repository merge lock"**
  (`c6732a4f00`, `9956c339e9`). `MergeLock` is a `WorkUnitLock` keyed
  `merge:repository:<id>[:branch:<name>]`, held by `auto_merge`,
  `merge_train_land`, `merge_train_land_after_rebase` and `external_pr_merge`
  only around their last sequence: check that the validated base is still the
  branch head, handle a moved base, merge, record. Waiters go first-come by
  landing start. *Relied-on invariant:* between a landing's head check and its
  merge, nothing else merges into that branch. Holds among those four steps.
  It does not hold against emergency landing, hotfix sync or promotion (Lead
  L15). `try_acquire` also returns a lock-free lease when the Workflow has no
  WorkUnit, which fails open; every landing Workflow is launched with one.
- **"Allow up to N concurrent landing units per repository"** (`bcdd2d3653`,
  `62a2f3f096`). `landing_concurrency` (1–5, default 1) gives each extra lane
  its own landing lock key, and the claimed lane is carried on the Workflow so
  every recomputation asks for the same one. *Relied-on invariants:* a Job is
  in at most one landing unit, and at the default of 1 landing behaves as
  before. Both hold: lane 1's key is unchanged byte for byte, and unit
  membership is still exclusive. `LandingSlot.lean`'s one-landing-per-repository
  property now holds per lane, and merge exclusion moves to the merge lock.
- **"Re-run only graders covering files touched by agentic landing rebase"**
  (`e1a7c79dcb`). After an agent resolves a landing rebase, only graders whose
  file scope covers a file the agent's resolution changed re-run; the rest
  carry forward. *Relied-on invariant:* a grader whose scope misses every
  changed file would pass again. This is the same assumption the clean-rebase
  path already makes, behind the same opt-in `trust_clean_rebase_grade`
  setting. Off, a full grader round still runs.
- **"Tolerate workflow doubles without work_unit when reading claimed landing
  lanes"** (`6cbc41776e`). A test-double guard.

## Lead L15. Emergency landing and branch publishes merge outside the merge lock

`EmergencyLand::Lander#merge!`, and the auto-merge paths of
`Steps::HotfixSyncPublish` and `Steps::PromotionPublish`, merge into a branch
without taking `MergeLock`. GitHub's `expected_sha` guards the PR's head, not
the base branch. So the merge lock's promise, that a landing merges onto the
base it just checked, breaks if one of these merges into the same branch
between a lane's head check and its merge call. The window is one GitHub API
round-trip, and a merge that lands before the check is caught as a moved base.
The race predates the lanes (the single landing slot never excluded these
paths either), but N lanes make landing merges more frequent. Not changed:
emergency landing is an operator override by design, so whether it should wait
for an in-flight lane merge is a behaviour decision. The likely fix is for all
three to take the same lock for their own merge call, which is milliseconds.

## M76. Main through `f476164c79`

A merge train for the instance connected accounts Epic. Accounts can be owned
by the instance. Discord and Telegram bot tokens move onto them, and Telegram
becomes a bundled platform plugin. `ConnectedAccounts::SystemInvocation` lets a
registered service use an instance account without a user.

*Relied-on invariant:* only the service that declared a system identity, using
an instance account of its own provider, can make a system invocation. Holds:

- `SystemInvocation.call` resolves the caller only from the `Binding` it was
  handed at registration (the proof is compared by identity).
- It requires the account's owner policy to allow system access.
- It checks that the registration's provider key, identity and service class
  are exactly the account's provider's declaration, and refuses a blank
  purpose.
- Every failure is the same denial.
- Registrations are keyed weakly by the binding, so a service that drops its
  binding loses access, and a reload mints a fresh proof that invalidates old
  bindings. Both fail closed.

What it does not stop is in-process code reading the private registrations
with `send`. That is the trust all plugins in one process share, and
`bin/check-plugin-boundaries` rejects it statically.

Checked after the rebase: mirrors match, boundaries are clean, and the
connected-accounts, formal, architecture and lock-order specs pass (1,153
examples).

## M75. Main through `3e5efbd613`

A merge train for the workflow-composition Epic. `Workflows::CompositionAnchors`
lets plugins contribute steps at three positions: judge loops after the review
gates, `post_implementation` steps before `dependency_audit`, and `post_pr`
steps after the PR steps. Visual review, coverage analysis and review planning
move into the browser, syrus_coverage and review_planning plugins.

*Relied-on invariant:* a plugin step cannot run against a HEAD the required
reviews have not approved. Holds without the barrier knowing about plugins.
`ImmutableReviewHeadBarrier` checks every downstream Run against the current
HEAD in `create_run_and_enqueue`, whatever its kind. A plugin step, or a judge
loop's re-implement, that advances HEAD therefore forces re-review exactly as a
core step does (`ReviewBarrier.lean`).

*Relied-on invariant:* a contributed step's failure handling matches its kind.
Holds: a `post_pr` contribution must declare the same `fail_policy` as its
`Step::Kind` entry, or it is rejected as an invalid contribution.

`formal/mirrors.yml` still matches, plugin boundaries are clean, and the engine,
workflow, step-dispatcher, formal and architecture specs pass (2,307 examples).

## M74. Main through `65e908a8c0`

A merge train for the plugin capability-family Epic. Toolkit extensions and
APIs, chat integrations, UI surfaces, surface contributions, Review and Policy
facets, service families, and Lifecycle and DataPolicy hooks all move onto
the family machinery, and the legacy Review and Policy bridge is removed.
*Relied-on invariant:* every contribution a plugin made before is still
registered and dispatched after, and a failing family dispatch stays isolated
to its plugin. Checked: `formal/mirrors.yml` still matches every mirrored
method, `bin/check-plugin-boundaries` is clean, and the specs that read the
registry through this branch's models pass. That covers formal, architecture,
chat MCP tools, coworkers (F108's registered pending actions), pending
actions, simulations and the lock order: 2,963 examples, 0 failures. Main's
`e785d9e7cd` tests the isolation itself.

## M73. Main through `0cf53b1982`

- **"Find Claude sessions under the cwd Claude Code actually reports"**
  (`0cf53b1982`). `ClaudeAgent::SessionPaths` encodes the cwd with symlinks
  resolved, as Claude Code does: macOS's `/var` is `/private/var`. *Relied-on
  invariant:* the encoded project is the same before and after the workspace
  directory is created, because resume restores a transcript before the run
  and captures one after. Holds: only the deepest existing ancestor is resolved,
  and the missing tail is appended verbatim. That tail would differ only if a
  later component were created as a symlink, and workspace directories are
  created as real directories. Relative paths are returned unresolved, and
  workspace cwds are always absolute.

## M72. Main through `987b8f4389`

A merge train for the Google Workspace Epic: read-only mail and calendar concept
plugins, a Google Workspace provider with calendar and Gmail read adapters,
locale and registry loading for provider-owned settings, and connected-account
secret clearing. They are plugin additions behind provider registration, with no
change to the work engine. The one engine change:

- **"Fix lock-order and conformance failures surfaced after merging main"**
  (`3378299a82`).
  - `BaseRefreshRetryEnqueuer#instantiate_retry!` now locks the source Workflow
    before the retry reserves a provider account. That is in order and removes
    the need for this branch's NY35 pending entry for that path, which is gone.
  - `AvailabilitySelector#pin_account!` writes the pin with `update_columns`
    instead of `update!`, "without locking the Workflow row". *Relied-on
    invariant:* a write that is not a `SELECT ... FOR UPDATE` takes no row lock.
    That is false: InnoDB takes an exclusive lock on every row an `UPDATE`
    changes, held to commit. The inversion (User, then Workflow) is still
    there; the suite's checker just does not see it (Lead L14).

## Lead L14. The lock-order checker sees explicit locks only, not write locks

`Syrus::LockOrder::Checker` hooks locking relation queries (`lock!`, `with_lock`,
`.lock`). An `UPDATE` or `DELETE` also takes an InnoDB exclusive lock on the rows
it touches, held until commit, so the order F110 proves acyclic covers only part
of the locks the code takes. The concrete case is main's `pin_account!`:

1. T1 holds the User row (the provider reservation).
2. T1 updates the Workflow row (`update_columns`), so it waits for that row.
3. T2 already holds that Workflow row and reserves, so it waits for the User row.

That is a two-way wait. NY36's option D removes this case by construction: a
NOWAIT User lock never waits, so T2 fails fast instead. The general gap remains.
Counting write locks in the checker will likely surface many "write a
lower-ranked row after locking a higher one" patterns, such as
`workflow.with_lock { job.update! }`. *Survey.* `SYRUS_LOCK_ORDER_WRITES=1` now counts every row-level write (`save`,
`update_columns`, `destroy`, through Active Record's class-level `_update_record`
and `_delete_record`) as a lock on that row. It is off by default, and
`update_all`/`delete_all` are not seen. The parallel suite in record mode with
writes counted found 73 distinct site pairs:

- **WorkUnit, then Steps, Workflow, Job, WorkIntent and Runs (about 900 hits).**
  `Workflows::LifecyclePropagation` calls `sync_work_unit_terminal!` first in
  every terminal transition, so `WorkUnit#mark_terminal!` writes the unit before
  the same transaction cancels Steps and Runs, updates the Job and settles the
  intent. WorkUnit is last in the order. The retry path's `mark_running!` has
  the same shape.
- **Job, then Run (131).** `Run#start` locks the Job (`before { job.lock! }`)
  and then saves the Run. The order puts Run first, and RunJob locks it first;
  paths that start a Run without locking it do not.
- **User, then Job or Workflow (72).** The provider reservation (NY36).
- **Step, then Workflow (64)** and **Job, then Epic (23)**: smaller groups,
  not yet traced.

So the order F110 proves acyclic covers explicit locks only, and the code's
writes do not follow it. InnoDB detects the resulting deadlocks and rolls one
transaction back, so the cost is a retried or failed transaction, not a hang.
Filed as NY37.

## M71. Main through `16254d1666`

Four commits.

- **"Update the Lean models my provider-backoff and orphan-grace changes
  touched"** (`16254d1666`). Main updated `QueueExecution.lean` and
  `CascadeReplay.lean` for the same two drifted mirrors this branch updated in
  F118. Main's `transit_never_flagged` relies on this invariant: a job in
  transit was just changed, so it is not `settled`. That fails for one job. The
  code's age check reads the job row, and a promotion moves only execution rows,
  so a long-scheduled job promoted mid-snapshot is old and still flagged. The
  rebase keeps both halves of the model: main's torn-read section, and F118's
  read order, now with `promoted_old_job_flagged` naming the case the grace
  misses. The fixture's `orphaned` is defined as main's `orphanedSettled`.
- **"Let a main repair that proved main healthy close itself"** (`f4caf4f261`).
  The same bug as F120, fixed in the shared iterator and for
  `preflight_inconclusive` too. *Relied-on invariant:* a repair whose preflight
  reached a verdict closes itself. Holds: `MainBranchRepair.after_success`
  closes it right after the health change. The branch's narrower skip is
  removed.
- **"Note a missing attachment file instead of crashing the agent step"**
  (`aca5bebc58`). *Relied-on invariant:* an attachment without a file is
  reported, never dereferenced. Holds: `JobAttachmentContext` checks for the
  file before reading its name.
- **"Let the WebKit e2e project reach its own assertions"** (`dd738c20df`).
  `signIn` returned before the SPA's first commit, and a later navigation
  raced the router's `replaceState`. That race may also explain Lead L10's
  CI-only signup and onboarding failures, which never reproduced locally.
  Recorded on L10, not closed.

## M70. Main through `3788b1a9b9`

Sixteen commits after this branch's last push to main (`deb8208602`). Two of
them changed methods `formal/mirrors.yml` watches, and one carried a bug (F118).

- **"Give a SolidQueue job time to settle before calling it orphaned"**
  (`600a716d44`). `orphaned_queue_job?` also requires the job to be at least
  `ORPHANED_QUEUE_JOB_GRACE` old. *Relied-on invariant:* a job with no execution
  row in the snapshot really has none. Counterexample: the snapshot read order
  misses old jobs promoted mid-snapshot. Fixed as F118, and the grace is now in
  `QueueExecution.lean`.
- **"Back off before rerunning a step that hit a transient provider error"**
  (`10876221e8`). A `provider_transient` infrastructure retry reopens the Step
  and schedules its Run after 1 or 3 minutes. *Relied-on invariants:* the retry
  stays bounded, and the reconciler leaves the waiting Step alone but still
  catches one whose wakeup is lost. Bounded holds: the limit is checked before
  the backoff, and each replay round still adds one Run (`CascadeReplay.lean`,
  doc updated). Being left alone holds. Catching a lost wakeup is open, as Lead
  L13: once the backoff has passed, `queued_step_without_run` skips any Step
  that has Runs, and `running_step_with_terminal_runs` skips any Step reopened
  since its last Run.
- **"Leave a retried Step alone while it waits for its turn"** (`98d30fa654`).
  `running_step_with_terminal_runs` skips a queued Step reopened after its
  latest terminal Run. *Relied-on invariant:* the retry's dispatch will reach
  the Step. That holds for a retry, whose earlier Steps run first; it is the
  other half of Lead L13.
- **"Do not flag graders that fan-out admission is still holding back"**
  (`1f52862907`). `queued_step_without_run` skips graders whose admission
  decided within 5 minutes. *Relied-on invariant:* fan-out admission re-decides
  every recheck delay while it holds graders. Holds: a stale decision ends the
  skip, so a stopped recheck chain is still caught.
- **"Close a main-branch repair still in preflight once main is healthy"**
  (`3788b1a9b9`), **"Keep a failed main-branch repair's workspace so its retry
  can resume"** (`9de293e519`). *Relied-on invariants:* closing goes through the
  same cancellation as a running repair, and the sweep only closes repairs that
  are unneeded. The first holds: it closes through `cancel_active_runs_and_close!`,
  and now also catches a queued repair. The second does not, and was wrongly
  marked as holding here at first. The repair whose own preflight just passed
  is closed as superseded by the health change it caused (F120). A
  failed infrastructure Workflow whose retry policy resumes the failed Step now
  keeps its workspace. The prune job still removes it after the failed-workflow
  retention window, so disk use stays bounded.
- **"Deliver an app event unsequenced when the sequence row is locked"**
  (`206ca9121a`). `next_sequence` failing with a lock-wait timeout or a deadlock
  now sends the event without `sequence`, which the frontend applies directly.
  *Relied-on invariant:* this runs outside any open transaction. A deadlock
  rolls back the whole transaction, so rescuing it mid-transaction would carry
  on with work that was undone. That holds for the broadcast paths checked so
  far, which run after commit; not every caller of `AppEvents` has been
  audited.
- **"Select a provider with no enabled account rows without raising"**
  (`c7b2166fe8`), **"Count a provider server_error toward the provider circuit"**
  (`b3a59d0470`), **"Do not resume a session created by a different provider"**
  (`29dc927a81`). Local guards. Each narrows an existing decision and adds no
  new state.
- The rest change logging, diagnostics, or deploy reporting (`164ed75177`,
  `b114e10708`, `8eb20127d0`, `d1e2a9f103`), git transport retries
  (`ceed13cb63`), or workspace-recovery replay safety for stranded preflight
  graders (`7b26940df9`, which widens an existing replay-safe set by one kind).

## Lead L13. A reopened Step whose Run never comes is invisible to the reconciler (closed: F119)

A queued Step that has only terminal Runs and was reopened after the last one is
skipped by both Step-level checks: `queued_step_without_run` requires no Runs at
all, and `running_step_with_terminal_runs` skips it as "waiting for its turn".
The Workflow-level `running_workflow_without_active_descendants` counts the
queued Step as active. So the Step's liveness rests entirely on whatever was
meant to create its Run. For a provider backoff that is a scheduled
`WorkflowPhaseAdmissionJob`. `WorkUnits::DeferredPhaseResume` returns without a
Run and without rescheduling on several branches ("unowned", "not_ready", a
provider-routing hold). Next: a spec that drops the scheduled resume and checks
the reconciler flags the Step once its backoff has passed and its predecessors
have handed off.

## M69. Main through `3561d3536a`

Two commits. `3561d3536a` installs WebKit dependencies for E2E CI. The other:

- **"Fix permission catalog snapshot classification on main"** (`3502624b0f`).
  `Permissions::Catalog.essential_for?` and `essential_everywhere?` take a
  `cache:` hash so classifying every descriptor reuses one registry and plugin
  snapshot. *Relied-on invariant:* the cached answer equals the uncached one.
  Holds: the cache is a local hash for one classification pass, registry
  entries are cached per surface (the only input the uncached lookup varied),
  and the plugin descriptors do not change within the pass.

---

## Lead L12. The review-barrier model has one way to pass; the code has three (closed: F116)

Found while preparing its conformance fixture (formal/INTEGRATION.md, layer 3).

`ReviewBarrier.lean` passes the barrier when the tracked HEAD was approved.
`Workflows::ImmutableReviewHeadBarrier.satisfied_for?` accepts, for each
required review: succeeded approved evidence for that HEAD; a review that
reacted without changing HEAD (`reacted_without_head_change?`); or a recorded
budget exhaustion for that HEAD (`exhausted_for_head?`). The exhaustion is a
deliberate exception, recorded with a high-severity workflow warning, that lets
a HEAD through which was never re-reviewed. So the model's headline property,
"whatever is pushed was approved by every required review", is about a barrier
the code no longer is: under exhaustion it is false by design. No fixture until
the model has all three paths, and its theorem is restated as "approved, or
reacted without a HEAD change, or a recorded and warned exhaustion".

---

## M68. Main through `1aa74a2a4d`

Ten commits. Nine are chat and mobile UI (sidebar scrolling and stickiness,
coworker thread collapse state, a chat index N+1, a missing-recent-chats
crash, visual-review docs) with no engine invariant. One is not:

- **"Make self-scheduled chat wakeups essential by default"** (`11d8bc436c`).
  `schedule_wakeup`, `list_wakeups` and `cancel_wakeup`, scoped to wakeups the
  current chat owns, become essential operations: evaluated and audited, but
  never asking. *Relied-on invariants:* an essential descriptor declares no
  barrier effect, and a chat can only touch its own wakeups. Both hold, and the
  commit's specs pin them. *What the change removes:* the
  `persistent_autonomy` effect was the brake on self-perpetuating work, and
  nothing replaces it. `ChatWakeup` has no per-chat limit, and the tool only
  bounds each wakeup's delay (1 minute to 24 hours, or a time within a year),
  so a chat can hold any number of pending wakeups, and a woken turn can
  schedule the next one, once a minute, indefinitely, each a paid agent turn,
  with no approval anywhere. Filed as NY34: it is a policy choice, so no code
  is changed.

---

## M67. Main through `a469015745`

Ten commits. Startup diagnostics (`b7abea2d8d`, `92e7d08f7a`, `3d3121d34f`), a
mobile coworker sidebar alignment (`eac45e6e55`) and formatting carry no engine
invariant. The rest:

- **"Harden core Job persistence against MySQL lock waits"** (`836d0ad0eb`).
  Adds attempt and exhaustion telemetry to RunJob's lifecycle-write retry and a
  retryable conflict response for bulk Job actions. *Relied-on invariants:* a
  retried block is idempotent, and the telemetry cannot fail a write. Both
  hold. Each retried block is one transaction (or a reload and one
  transaction), so a lock wait rolls it back whole; `Workflow#record_run_failure!`
  documents the same. The counter is declared `run_lifecycle_lock_retries_total`
  and fetched as `syrus_run_lifecycle_lock_retries_total`, which matches,
  because every core declaration is prefixed `syrus_`. One residue: a lock wait
  inside a Step's after-commit cascade, after the success committed, is retried
  into a reload that finds the Step terminal and returns, so the cascade is
  dropped. That is the lost-cascade shape the reconciler already repairs, and
  F102 makes the repair replay it.
- **"Enable QA coworkers to perform visual acceptance reviews"** (`4918d4d863`).
  Opens `run_visual_review` and `run_visual_diff` to coworker roles. *Relied-on
  invariant:* a coworker tool skips the generic approval only when its card is
  backed (F108). Holds: both are core tools whose `approval_effect` is derived
  from their registered pending actions.
- **"Require explicit plugin release metadata"** (`07eb776139`, `bf8a33a67c`)
  and **"Fix merge-readiness integration regressions"** (`a469015745`). Plugin
  manifest metadata and plugin-health reporting. They rewrite part of
  `lib/syrus/plugin_registry.rb`, which F93 changed; the rebase merged cleanly,
  and F93's specs, the plugin enablement guard, the Coworkers and Local Backups
  plugins, `spec/lib/syrus`, the architecture specs and both RunJob lock-wait
  specs pass on the result with the lock-order checker raising (1,859
  examples).

---

## M66. Main through `29c22a4edd`

One commit: macOS workers run the release's pinned Ruby through mise. Worker
provisioning only; no engine invariant.

---

## M65. Main through `ebbcb88009`

Five commits. `25b268d453` (previous-failures gate JUnit), `ff64d942f9` (enable
Design Docs for E2E) and `ebbcb88009` (keep macOS credential helpers out of
git calls) carry no engine invariant. The rest:

- **"Cancel a superseded CI repair held behind a main repair"**
  (`39f7f9c254`). *Relied-on invariant:* a CI repair whose base main has moved
  past is cancelled whatever block holds it. Counterexample on the queued
  path: F109.
- **"Write GitHub rate-limit snapshots after the transaction commits"**
  (`9aadb46309`). *Relied-on invariant:* a GitHub call inside a transaction
  takes no lock on the calling user's row. Holds: both writes (the snapshot
  and the API-blocked mark) now go through `after_all_transactions_commit`,
  and the client's only other write (`mark_installation_removed!`) is on the
  installation row. One gap that predates the change: Lead L11.

---

## Lead L11. The rate-limit block mark is lost when the exhausting call's transaction rolls back

A GitHub response with `remaining: 0` sets the user's API-blocked mark. Since
`9aadb46309` the mark is written after the outermost transaction commits, and
before it the UPDATE ran inside that transaction; either way, a rollback drops
it. The exhausting call is often the one that raises (a 403), and an exception
that leaves a transaction rolls it back, so the call most likely to exhaust the
limit is the one whose mark is most likely lost. Later calls outside a
transaction re-observe the headers, so this delays the mark rather than losing
it for good. No production evidence yet; check `gh_rate_limit_*` against
403s with remaining 0 before fixing.

---

## M64. Main through `d381b27bd3`

Four commits, all mobile review gestures (cue visibility, localized cue fit,
swipe reveals). No engine invariant.

---

## Lead L10. E2E on main: one new failure fixed, two that only fail in the full CI run

*Update (M71):* main's `dd738c20df` found that `signIn` returned before the
SPA's first commit, so the next navigation could race the router's
`history.replaceState`. That is CI-timing dependent, as these failures are, and
is a likely cause. Re-check the two after the next E2E run on main.

Main's E2E workflow has been red for at least fifteen runs. On `46989b055f`
it fails three tests:

- **`admin-panel.spec.ts`**, new with the plugin registry UI. The page gained
  an "Install external plugins" heading, so `getByRole("heading", { name:
  "Plugins" })` matched two elements under strict mode. Fixed on the branch
  with `exact: true`; it passes locally.
- **`signup.spec.ts`**, failing in every listed run. After signing out from
  `/onboarding`, the page stays on `/onboarding` instead of `/session/new`.
  It passes locally when run on its own (8.8s). The server's sign-out answers
  `redirect_to: /session/new`, so the redirect comes from client or database
  state.
- **`onboarding.spec.ts`**, failing since about `e6aa5d7d0e`: the Dashboard
  heading never appears after the checklist completes.

Ruled out locally (macOS): ordering, since the whole core project in CI order
passes, 59 of 59 in 11.8 minutes; and time zone, since onboarding and signup
pass under `TZ=UTC`. The E2E workflow sets no other environment. What is left
is the platform: CI runs Linux Chromium on the GitHub runner. Next step: run
the pair in the Linux worker image, or have CI upload the Playwright error
context for failed tests (it uploads no artifacts today).

---

## M63. Main through `9a3ed75dbb`

Forty commits, one Epic: deterministic plugin packages, ed25519 signing, trust
stores and revocation, a staged installer, and multiple plugin registries with
registry-scoped trust. Relied-on invariants:

- **A signer owns the name it signs.** Counterexample: F103.
- **No version means the newest version.** Counterexample when a registry is
  named: F104.
- **A non-canonical registry never grants "official".** Holds: the listing and
  the cached trust store used at install both go through
  `PluginRegistryClient#trust_store`, which caps the label to "verified" for
  non-canonical sources.
- **A revoked release is never staged, confirmed or left installed.** Holds:
  `Verifier` refuses revoked keys and releases, `stage_release!` and
  `confirm!` re-check against the release's own registry's trust store, and a
  trust-store update writes a pending file that `RevocationReconciler`
  applies before it becomes current. The reconciler runs again on the next
  load if a crash interrupts it, so quarantine is not lost.
- **Trust never crosses registries.** Holds by construction: each registry has
  its own cached trust store, and revocation reconciles only that registry's
  installations.
- **Registry files stay inside the index root.** Holds:
  `read_registry_file` resolves real paths and requires containment, so a
  symlink cannot escape.
- **Downloads are HTTPS, size-bounded, SSRF-guarded and digest-checked.**
  Holds in `PluginRegistryPackageFetcher`.

---

## M62. Main through `e09f7fbc78`

Eleven commits. Seven are mobile review UI (gestures, evidence carousel), and
`eb1b9e1b0f` pre-pulls the app image before a rollout. The rest:

- **"Supersede a main repair still in preflight when main advances"**
  (`6c5cc09b25`). It closes a running repair, as `superseded`, when its
  preflight snapshot is an older commit than the new head and `implement` has
  not started.

  *Relied-on invariant:* a still-broken new head gets its own repair at once.
  The suspected counterexample was the 30-minute
  `suppressed_by_recent_closed_repair?` cooldown, which applies to every closed
  repair except merged ones. A spec shows it does not bite here: closing the
  stale repair already drives the health flow, which spawns the replacement.
  The spec ("spawns a fix Job for a still-broken head right after superseding
  a stale preflight repair") passes with and without excluding `superseded`
  from the cooldown, so it is kept as a pin and the code is unchanged.

  It also composes with F100: a *failed* repair with a pending retry is not
  `running`, so supersession skips it, and `retrying_fix_job` keeps blocking a
  second spawn.
- **"Say why the spec harness could not set beta mode"** (`e09f7fbc78`). The
  spec harness now prints the error it used to swallow when setting beta mode.
  The next CI run should name Lead L9's cause.
- **"Compare a grader shard against its whole family's base failures"**
  (`fd9a97e43c`). This is grader base-failure attribution for sharded graders,
  in grader tooling. No engine invariant.

---

## M61. Main through `7a6949c328` — main green again, the F88 spec settled on main

Main's grader went red after this branch was pushed to main. There were three
causes:

- `spec/models/workflow_spec.rb` (CI-only) still pinned the pre-F88 behaviour,
  that a failed `coding_handoff` leaves its Job running. **This branch caused
  it**: the gate ran the CI-only specs only for the areas touched, and missed
  this file's interaction.
- `installer_spec.rb` failed once, depending on order: an extra `:install`
  after beta mode was switched off, from a stale read. It does not reproduce
  locally in random orders or alongside its shard companion. Left as a flaky
  spec to watch.
- A TypeScript type error in the startup diagnostics test.

Main fixed them itself:

- "Bring the coding-handoff failure spec in line with settling the Job"
  (`7a6949c328`) keeps F88's behaviour and updates the spec. This branch's
  own fix for the same spec was dropped in the rebase as redundant.
- "Type-check the startup diagnostics script test" (`e545e6b579`).

**"Release a lost workspace that no live Run uses instead of failing"**
(`e605c3b1ae`). When reconstruction fails, `WorkflowWorkspaceRecovery` now
checks whether every active Run is placed outside the mutable workspace
(immutable checkout, control plane or external context). If so, it releases
the dead worker's routing hold and requeues the stranded Runs instead of
failing the Workflow.

*Relied-on invariant:* nothing that reads the mutable workspace runs against
a lost one. This holds:

- the release requires every active Run to be workspace-free;
- a workspace-bound Step that starts later finds the workspace missing and
  goes through recovery again, so it can still require a fresh attempt.

This is the Lead L7 area: it also clears the affinity that L7's requeue was
working around.

**Process note.** Before the next push to main, run the full CI-only suite,
not a subset.

---

## M60. Main through `357448bbd0` — the outage's cause, NY30 implemented, repair cap windowed

This branch was fast-forwarded into main at the operator's request
(`147cdbb145`). Thirty-four main commits are reviewed here: ten from just
before the push (frontend handled-error reporting, review navigation, lint
rules, all frontend) and twenty-four after it. The ones that touch invariants
proved or fixed here:

- **The outage's cause** ("Reserve a grader's declared memory, and declare it
  for the e2e suite", `357448bbd0`). Every pod death in M59 lined up with an
  e2e grader. Host admission charged the Playwright suite one generic unit
  while its Rails server, Vite and Chromium used several GB. Hosts reached 99%
  memory until a pod was OOM-killed, once taking the MySQL node and so every
  process. A grader's declared `resources.memory` is now the floor of its
  reservation, and each e2e shard declares 4 GB. The e2e suite also runs as
  three shards (`e40f316d8e`), and main-repair preflight runs in lanes
  (`f587417455`).

  *Relied-on invariant:* a reservation larger than a host can offer must not
  starve. It holds, because `memory_capacity_full?` returns false on an idle
  host ("soft estimates must not deadlock an otherwise idle host"), and hard
  measured pressure is handled separately.
- **NY30 option A** ("Repair a reproducible main failure even when another
  grader is unproven", `5b86f0d8b7`). `PreflightGraderCollect` now proceeds to
  implement when at least one required grader failed reproducibly. It records
  graders with no result as `preflight_unproven`, and the repair's grade loop
  re-runs them. With no reproducible failure, an unproven grader still keeps
  main inconclusive.
- **The repair cap** ("Stop counting old failed repairs toward the main-repair
  cap forever", `7b8f5e722b`). Only failed repair Jobs from the last six hours
  count toward `MAX_OPEN_FAILED_FIX_JOBS`. That composes with F100:
  `retrying_fix_job` reads the uncapped failed set and runs before the cap, so
  a failed repair with a pending retry blocks a new spawn however old it is.
- **Main CI from grader-only health records** (`31c1ba80f2`, `6b9232ae59`).
  This addresses the stale `ci_health: broken` that kept spawning repairs in
  F100 while the grader said healthy. Not reviewed further here.
- **Lock-wait diagnostics** (`f6a48f8fb3`, `1492e2c4a7`, `7ed01897de`). A MySQL
  lock-wait timeout now records what held the rows. That is Lead L8's
  "next step if it recurs".

Rebased without conflicts.

---

## M59. A production outage on 11-22 (read-only observation, cause unknown)

**Timeline (UTC).**

- **13:28 and 13:59:** two worker-compute pods were replaced without a deploy,
  on the same version `424204c35b`. Runs on them failed `worker_died`. That
  included a main grader's `e2e` grader, twice, which failed two main graders
  as "required graders failed due to infrastructure". It also included the
  graders of a main-branch repair, whose Workflow then failed with
  `workspace_recovery_failed` and was relaunched.
- **About 14:59:** `/up` returned 503 Service Unavailable, and the admin API
  returned 500/502 or hung for over two minutes.
- **15:10–15:13:** every instance restarted on the same version: the web,
  preview, all six workers and the home worker. A Mac worker on the old
  version `6570ee323f` also reconnected. `/up` was back to 200 by about 15:13.
  A few Runs that were in flight failed `worker_died` and are retried
  automatically. No Workflow failed afterwards.

**Not known.** Why the pods died, and why the whole stack went down. From
this session, the cluster is not reachable (kubectl is blocked), and the
database can only be read through the admin API, which was down. Worth
checking against the previous production failures in the operator notes:
MySQL OOM kills from glibc arena retention, and a MySQL volume filled by
`--log-output=TABLE`. The two earlier pod deaths may have been the first sign.

**After the restart (UTC).** Worker pods kept being replaced, all on the same
version `424204c35b`:

- compute `rnfjm` at 15:34, then `j27bx` at 16:07;
- the old-version Mac worker (`6570ee323f`, data root 85–86% full) at 15:38
  and again at 15:52.

Each restart fails the Runs on that worker as `worker_died`. The two
concurrent main-branch repairs (F100) were cancelled at the operator's request
at about 15:55, and `j27bx` still restarted afterwards. So the duplicate
repair load was not the only cause. The cause remains unknown from this
session.

---

## M58. Main through `c2e7a2f7cb` — main's React failure fixed by hand, coworker ref filter equivalent

Two commits.

- **"Wait for lazy plugin panels in carousel specs"** (`c2e7a2f7cb`) fixes the
  two `pluginUiSlots.test.tsx` failures from M55 and M56. They now pass
  locally on the rebased branch. Main was repaired by hand, not by the
  main-branch repair that NY30 describes, so NY30 stands for the next time.
- **"Harden remote workspace command construction and coverage"**
  (`fd19193276`, Coworkers plugin) replaces a per-ref
  `merge-base --is-ancestor <sha> refs/remotes/workspace/home` loop with one
  `for-each-ref --merged=refs/remotes/workspace/home`.

  *Relied-on invariant:* the selected run refs are exactly those whose tip is
  reachable from the home branch. `--merged=<commit>` lists exactly the refs
  whose tip is reachable from `<commit>`, which is the `--is-ancestor` test, so
  the set is unchanged. Ref names cannot contain spaces, so the
  whitespace-split parse is safe.

  *Not changed by it:* `ref.split("/").last` would truncate a run branch with
  a `/` after the prefix. The branches Coworkers creates have none.

Rebased without conflicts.

---

## M57. Main through `e6aa5d7d0e` — the permission matrix optimisation preserves decisions

One commit: "Speed up permission rule specs with cached payload lookups". It is
an app-code change, not only specs.

**What changed.** `Permissions::RulesPayload` now groups the active rules by
`subject_selector_type`. For each subject it passes only that subject's rules,
and their policy rules, into `Management#matrix_state`. Previously every
subject's matrix state was explained against *all* active rules.

**Invariant it relies on.** A rule of one selector type never decides a
matrix cell for another. This holds: `PermissionRule#to_policy_rule` puts the
rule's own `subject_selector_type` into its selectors, and `matrix_state`
explains with `context: { subject_selector_type: … }`. A rule whose selector
type differs from the context can never match, so filtering it out
beforehand cannot change a decision.

This includes the `eligible_roles` selector. Its `subject_role_keys` would
have suggested cross-subject reach, but they are not part of the policy
selectors.

Rebased without conflicts.

---

## M56. One timed-out preflight grader stopped the repair of a reproducible main failure (NY30)

**Production (read-only, 11-22).** The `main_branch_repair` from M55
(Workflow 66236) ran 134 preflight graders. Two did not pass:

- `react-tests-ci` failed with a genuine assertion failure (`test_failed`):
  `pluginUiSlots.test.tsx`, reproduced locally on `7fe0e61d29`.
- `e2e` timed out after about 25 minutes (exit 124).

`Steps::PreflightGraderCollect` then logged:

```
required preflight graders have no conclusive result: e2e (inconclusive: timed_out)
— main health stays inconclusive, not spawning a coding repair
```

It skipped `implement`, every grader step, `summarize`, `test_plan` and
`pr_open`. `Workflows::MainBranchRepair.mark_inconclusive!` set the
repository's grader and CI health to `inconclusive` and closed the anchor Job
as `preflight_inconclusive`. The Workflow *succeeded*.

**Why.** This is the documented rule:

- `GraderOutcome` classifies a timeout as `inconclusive`, not
  `infrastructure_failed`, so `retryable_infrastructure_failure?` never retries
  it. Note that `GraderCollect` lists `timed_out` among its infrastructure
  classifications.
- `PreflightGraderCollect` makes the whole preflight inconclusive whenever any
  required grader is unproven, "even when another grader reproducibly failed",
  so that a repair never proceeds on partial evidence.

**Result.** Main is genuinely red on two React tests, but:

- its health reads `inconclusive`, not unhealthy;
- landing is not paused;
- the repair Job is closed;
- no coding repair runs.

Whether this ever ends depends on a later main grader both failing
`react-tests-ci` and getting a repair whose `e2e` preflight does not time out.
A slow e2e suite under load can keep re-masking the failure.

**Also observed.** The newer main grader, Workflow 66241, ran only 22 graders,
apparently not `react-tests-ci`, and succeeded at 05:20. At 06:22 the repair,
deciding from its own earlier evidence, stamped `inconclusive` onto the
current `last_health_checked_sha`. Here that is closer to the truth, but it is
a verdict about one commit recorded against another.

---

## M55. Main through `7fe0e61d29` (the Ecosystem family migration), and main's broken React test

**Epic #554** (25 commits) does two things:

- migrates every bundled language plugin to the Ecosystem capability family;
- removes the legacy `prepare_detector`-style extension points, routing core
  ecosystem lookups (prepare plans, grader coverage, dependency audits)
  through `Syrus::Plugin::Dispatch`.

It relies on three invariants this branch already proved or fixed:

- **Only conforming declarations are invoked.** That holds for dispatch, the
  bridge and the detector (F94). It now matters for every bundled plugin, not
  a latent external one. `RepoPluginDetector` is now
  `preview_provider` plus the family language-support path, and F94's
  per-manifest conformance gate merged unchanged.
- **The capability lookup fails closed when enablement cannot be read**
  (F93). Core Prepare now goes through that lookup, so a database outage now
  retries and then raises in Prepare instead of running every installed
  plugin. That is the behaviour decided for NY13.
- **`restore_built_ins!` keeps built-in families** (M53).

**Rebase.** The only conflicts were `host/public_apis.rb` (main added
`capability_providers` and three Ecosystem value types; this branch added
`providers_with_owner_for`, so both are kept) and the regenerated
`plugin-spec.md`. `bin/check-plugin-boundaries` passes. `spec/lib`,
`spec/architecture`, the detector, every plugin's specs, `spec/services/steps`,
the plugin admin requests, and this branch's touched specs pass, CI-only
included: 9,774 examples.

**Main is red on two React tests (production, read-only, and reproduced
locally).** `app/frontend/pluginUiSlots.test.tsx` fails twice. The test expects
"1 unlabeled open issue" from `screen.findByRole("status")`, but receives
"Loading...". That is the lazy plugin component's new loading status, from
"Give suspending plugin components a loading state, not an error"
(`2f0c0f60a3`). M45 waved that commit through as not engine-relevant; it
needed its tests run.

A `main_branch_repair` (Workflow 66236) is already working on it. Its
preflight graders reproduce `react-tests-ci`, and an `e2e` timeout too. So
this branch leaves the fix to that repair rather than racing it with a
conflicting change. The main grader that triggered the repair failed first on
F98's misclassified `npm ci` error; the React failure was underneath it.

---

## M54. An unpublished stacked child whose work conflicts with its moved parent has no recovery (NY29)

**Found by** the failure sweep (production, read-only, 11-22). Epic 553 is a
linear chain, 9452 → 9453 → 9454 → 9455 → 9456. Job 9453's initial Workflow
ran a grader loop from 11-19 to 11-22, then failed at `pr_open`:

```
stack_base_freshness: stack base syrus/direct-9452 moved (5f15df7d -> b0bb597b); rebasing completed work (attempt 1/3)
CONFLICT (content): Merge conflict in cli/cmd/plugin_local.go
error: could not apply b3b225b2f... Add plugin package signing and trust verification
FAIL: Steps::PrOpen::AwaitingStableBase: rebasing completed work onto syrus/direct-9452 (b0bb597b) failed
```

The parent had been restacked onto main after the plugin capability-family
Epic landed, and that Epic changed `cli/cmd/plugin_local.go`, which 9453's own
first commit also edits. This is a genuine content conflict. An auto-retry
(`retry` Workflow 66238) replayed the same mechanical rebase twice and failed
the same way. 9453 is failed, and 9454–9456 wait on it (M49).

**Why nothing recovers it.**

1. `StackBaseFreshness#rebase_onto!` raises `RebaseConflict` on a conflict.
   `Steps::PrOpen#raise_awaiting_stable_base!` converts every
   `StackBaseFreshness::Error` into `AwaitingStableBase`. The artifact keeps
   `reason: rebase_conflict`, but the failure is classified
   `awaiting_stable_base`, which is *retryable*. That is right for a parent
   that keeps moving, and pointless for a conflict: every retry repeats the
   same deterministic rebase.
2. The path that can resolve conflicts with an agent is
   `StackRebaseCoordinator#enqueue_rebase`, a Rebase Workflow. It skips a child
   with no PR (`return if child.pr_number.blank?`). A child that fails *at*
   `pr_open` has never published one.
3. The coordinator does supersede a pending `awaiting_stable_base` retry with
   a stack rebase (`SUPERSEDABLE_RETRY_CLASSIFICATION`), but only for children
   it is willing to rebase. Point 2 excludes this one.

So an unpublished stacked child whose completed work conflicts with its
parent's new base ends failed, and takes the rest of its chain with it, until
an operator rebases by hand.

---

## M53. Main commits through `127ea3b964` — the external-reviewer contract

Five commits, one Epic merge. They add a provisional `review` plugin family
with one `external_reviewer` capability (`first_claim`, absent `nil`), the
`Syrus::Plugin::ExternalReviewer` service contract, its value types, a
contract test kit and a fake provider. Nothing in the engine calls it yet.

**The one new core invariant.** `Family.define(..., built_in: true)` plus
`restore_built_ins!` keep the built-in families across a registry reset.
`restore_built_ins!` uses `Hash#replace`, which copies the entries instead of
aliasing the hash, so a later `define` cannot leak into the built-in set.

The rebase conflicted only in the generated `plugin-spec.md`, which was
regenerated. After the rebase, `spec/lib`, `spec/architecture`, the detector,
classifier, plugin admin, work unit, work intent, lifecycle and filter specs
are green (2,154 examples), CI-only included.

---

## M52. Job state drift has stopped since the 11-21 deploys (read-only)

Coverage item `job-state-matches-latest-workflow`.
`unambiguous_job_state_drift` was applied 40, 37 and 62 times a day on 11-18
to 11-20, and 14 times on 11-21. All of those 11-21 cases came before about
22:00 UTC, when `d9be256158` and `424204c35b` went live. The shapes were the
F20 and F33 ones:

- queued → running and implemented → running under a running Workflow;
- running → implemented or failed after the Workflow finished.

There were none in the following five hours. Too short a window to call
closed. The check-then-act on a cached Job in `JobLifecyclePropagation`
(decided without reloading under the Job lock) remains the open hazard for
this item.

---

## M51. Merge-train sweep (read-only): F25 verified, terminal hooks noted (Lead L6)

**F25 verified in production.** The reconciler detected
`succeeded_merge_train_failed_member_reconciliation` 9 times between 11-17 and
11-20, 18:12 UTC. Each detection came within about 30 s of a successful train
finishing, with 1–7 members wrongly failed per train. That is F25's
signature: a member that landed through the integration rebase was rejected
by the pre-rebase ancestry check.

Since the 11-21 deploys, five trains have landed (three Epics and two Job
bundles) with no detection. That includes the plugin capability-family Epic's
train, which landed through `merge_train_land_after_rebase`, F25's exact path.

**`stale_active_merge_train_without_runtime`.** Two repairs, both on 11-16,
none since.

**Lead L6: terminal hooks swallow their errors.** `Workflow#dispatch_hook`
rescues `StandardError` and only logs it. `Workflows::MergeTrain.after_fail` /
`after_cancel` run `MergeTrainFailureHandler` through it, inside the
terminal transition's transaction and with no savepoint. If the handler raises
partway through:

- the Workflow still commits as failed or cancelled;
- whatever the handler wrote before the error commits with it;
- the train can be left active with no owner. That is the
  `stale_active_merge_train_without_runtime` producer that coverage item
  `stale-active-merge-train` lists as "atomic terminal hooks".

The reconciler backstops the stale train (F43). Making it unreachable would
mean either failing the transition when a hook fails, or running each hook in
a savepoint and recording the failure for retry. Either changes a deliberate
"a hook never blocks a transition" contract that every Workflow kind shares,
so it is left as a lead, not changed. The swallowed exception leaves only a
log line, so production cannot show how often it happens.

---

## M50. Landing units can deadlock on a cycle the Job graph does not have — proved, latent (NY28)

Coverage item `landing-queue-order` named the order computation as unmodelled.
`LandingQueueProcessor#ordered_landing_units` contracts each Epic to one
landing unit (its merge train) and sorts the units topologically, appending
any cyclic remainder. A unit is blocked while a transitive prerequisite
outside it is not closed (`transitive_blocker_jobs_for` /
`dependency_blocker?`).

`JobDependency#no_cycle` rejects cycles in the *Job* graph only. The derived
Epic edges (`EpicDependencies::DerivedEdgeReconciler`) relate only Epic to
Epic, so a path through an Epic-less Job is never contracted. Take Epic child
J1 ← outside Job J2 ← Epic child J3:

- each edge is accepted, and the Job graph is acyclic;
- the Epic's unit waits for J2, J3's prerequisite;
- J2 waits for J1, which only lands with the Epic's train.

Neither unit ever becomes landable.

`formal/SyrusModel/LandingUnitCycle.lean` checks four Jobs, up to two Epics
and every dependency relation (332k cases):

- `contracted_acyclic_progress`: when the Epic-contracted graph is acyclic,
  some unit is always free to land;
- `epic_through_outside_job_deadlocks`: the counterexample blocks both units;
- `job_acyclic_not_enough`: Job-level acyclicity does not imply the
  contracted condition.

**Production (read-only).** No Epic child has ever depended on an outside Job
that depends back into the same Epic, so nothing is stuck today. The shape is
reachable by filing dependencies, so whether to refuse it is NY28.

---

## M49. Epic-conflict victims in production: every one was relaunched or legitimately held

Coverage item `epic-conflict-victim-not-relaunched`. Every WorkUnit cancelled
for `epic_wide_workflow_active` in the last 21 days was checked (read-only),
51 units across 31 Jobs:

- **Relaunched or finished.** Every victim's Job either got a later unit on the
  same intent or a later Workflow, and all but three Jobs are closed.
- **Three legitimately held.** Jobs 9454 → 9455 → 9456 of one Epic chain are
  queued, with intents `waiting` on `dependency` and no later work. Their first
  predecessor, 9453, *failed*. That is a correct hold behind a failed
  predecessor, which `JobWakeup` starts once the dependency is satisfied. It is
  not a stranded victim.
- **Relaunch-into-cancellation loops, both before F34 was deployed.** These are
  the once-a-minute relaunch loops F34 describes:
  - Job 8686: 6 cancellations on 11-07;
  - Job 9449: 10 cancellations on 11-20 and 9 more on 11-21, between 13:39
    and 13:48 UTC.

  F34 (`31b7c3e224`) reached main at 17:00 UTC on 11-21, after the 11-21
  loop. It was first deployed in `d9be256158` (21:53 UTC). The workers live at
  13:39 ran a version without it.

There have been no Epic-conflict victims since 13:48 UTC on 11-21, so F34 is
not yet *observed* under load, only unrefuted. The item stays partial: there
is still no proof that every victim of a running-member/running-keeper race
is relaunched.

---

## M48. Auto-retry is bounded in production — audit, no new counterexample

Coverage item `auto-retry-bounded` asks whether a budget-exempt skip whose
cause persists re-plans forever. Seven days of `auto_retry_attempts` were
grouped by Job, reason, kind, classification and provider (read-only):

- **"job branch was rewritten since the source run recorded its workspace"**
  ran 324 times on one Run in 27 minutes, all attempt 1, as a `retry_workflow`.
  That is the F44/F45 loop.
  - Both worker versions live then, `4a424455d6` and `637033715e`, predate F45
    (`cbbfcc5b39` landed on main at 12:00 ET).
  - Since `d9be256158` (F45 included) went live, there have been none.
  - The second instance (69 rows, 11-16) predates both fixes.
- **"Job is already approved for landing"** (33 rows, one Job): every row is a
  different failed Run, one skip each. Bounded by the Runs; no re-planning.
- **A `grader_collect` Step retried in place 11 times** (attempt numbers up to
  14, hourly, 11-16). This is F22's superseded-iteration cycle, already fixed.
  It stayed inside the budget, because `worker_died` is budgeted at
  `MAX_WORKER_DIED_ATTEMPTS = 20`, not `MAX_ATTEMPTS = 3`.
- **No other reason repeats on a Job.**

The budget-exempt reasons that persist in production are all ones the planner
now excludes. "That agent is not available" never appeared in the window.

---

## M47. Failure sweep (read-only): recent fixes verified in production

Main had no new commits. The sweep looked at failed Runs and Workflows in the
last three hours, and reconciler repair activity over two days.

**Run failures.**

- Grader failures are real test results.
- One implement Run failed with `worker_died`, and a second Run on the same
  Step succeeded.
- The merge-train `merge_train_land` failure was the designed fallback: land
  failed, rebase, `merge_train_land_after_rebase` succeeded.
- No Workflow failed or blocked.

**Repair loops, both stopped after their fixes deployed.**

- `clear_waiting_work_intent_active_unit` ran 4,000–6,000 times a day through
  11-20. It hit the same intents every minute: Epic children whose queued
  Workflow's intent `JobWakeup` parks on `dependency`. It stopped once
  "Stop the reconciler undoing justified dependency waits" deployed, and has
  applied once since.
- `resume_queued_step` was refused once a minute on one Step behind
  `ci_repair_safety` until 12:36 UTC on 11-21. F40 is deployed, and since then
  only one-off `not_ready` skips remain, each on a distinct Step.

**Late "nothing left" detections.** Explained and fixed in F96.

**Full-suite gate** (`bin/rspec-fast`, 24,587 examples): one order-dependent
failure. `chip_contract_spec.rb` found the latest-workflow trigger-kind filter
chip offering `coworker_run` after an earlier spec had taken it out of the
registry. The chip copied `Workflow::TriggerKind.values` at class load. In the
product that meant a disabled plugin's kinds stayed selectable, and kinds
registered later were missing. It now reads the registry on every call, with
a deterministic regression example. The filter specs (985) are green.

---

## M46. Main commits through `2bfca771f5` — unread-only chat sidebar, invariant holds

Four frontend commits after `31254a466c` stop the recent-chats sidebar from
refetching, and from resetting its loaded sections, on every navigation in
unread-only mode. The route's chat id leaves the query key. The open chat is
tracked in a module-level `openRecentChatId`. On navigation, the previously
open chat is dropped locally. A mark-read response is now applied even after
the route has moved on (`updateChatUnread`, not a refetch).

**Relied-on invariant:** in unread-only mode, the list shows exactly the
unread chats plus the open one.

**Checked:**

- **The mark-read response lands before navigation.** The chat stays while
  open (`openRecentChatId === id`). Leaving it finds it read in the cache, so
  it is dropped.
- **The response lands after navigation.** The navigation effect still sees it
  unread and keeps it. The late `updateChatUnread` then drops it, because it is
  no longer the open chat and no longer in the query key.
- **The open chat came only from "show more".** It is not in the query cache
  at all. The navigation effect reads "not unread in the cache" and drops it
  from the loaded sections, so it cannot linger as read.
- **The sidebar unmounts while a chat is open.** `openRecentChatId` goes to
  `null`. A later mark-read removes the open chat from the unread-only cache,
  which is correct for the next mount.

**Lead L5 (not fixed, self-healing).** The navigation effect decides "still
unread" from the query cache alone, and `updateChatUnread` never patches the
loaded sections. A chat reached only through "show more" whose mark-read
*failed* is dropped on navigation although it is still unread. It reappears on
the next refetch (30-second stale time, or window focus). Deciding from the
loaded sections as well would need `updateChatUnread` to reach them first.
Otherwise a successfully read chat from a loaded section would be kept as
unread.

---

## M45. Main commits through `31254a466c` — the plugin capability-family epic

Forty-one commits landed on main after `d9be256158`:

- the plugin capability-family epic (merge `31254a466c`);
- e2e spec maintenance;
- a loading state for suspending plugin components.

The rebase conflicted in `plugin_registry.rb`, `host/public_apis.rb` and the
generated `plugin-spec.md`, where this branch's NY13 enablement read and
`providers_with_owner_for` met the epic. The conflicts were resolved by
keeping both. The plugin docs were regenerated with `bin/generate-plugin-docs`.

**Invariants the epic relies on, and how each was checked:**

1. **An unreadable enablement table never enables a plugin (NY13).**
   *Counterexample:* `available_capability_plugins` rescued and kept every
   plugin. Fixed in F93, with a structural guard.
2. **A non-conforming family withholds only that family.** Holds for
   `providers_for`, the legacy bridge, `capability_providers` and the health
   state. `non_conforming` replaces only `:ok`, so a plugin that is also
   degraded stays unhealthy. *Counterexample:* `providers_with_owner_for`,
   which is on this branch only. Fixed in F93.
3. **A family capability is only invoked through a conforming declaration.**
   Holds for `Dispatch`, `LegacyBridge` and `capability_providers`.
   *Counterexample:* the detector's language-support path. Fixed in F94.
4. **A plugin's failure does not take down core work.**
   - `Dispatch` invokes through `PluginInvocation`. A `ValidationError` passes
     through deliberately, without counting against health.
   - The detector rescued only `StandardError`, while a lazily resolved
     provider can raise `ScriptError`. Fixed in F94.
5. **Conformance results are never stale.** The `conformance_for` cache is
   keyed by `[generation, sorted manifest names]`, and every `register` and
   `reset!` bumps the generation, so a changed manifest set is never answered
   from an old entry. Old keys are never evicted. Generations only advance at
   registration (boot, test reset), so this is bounded in production.

**Not engine-relevant:** e2e spec updates, the plugin error-boundary loading
state, the admin plugin capability table and CLI `plugin capabilities`, the
scaffold and authoring guide, and generated catalogs.

---

## M44. Main commits through `d9be256158` — invariants checked, no counterexample

Thirteen commits landed on main after `05d1c36ce1`. The branch rebased onto
them without conflicts. The invariants they rely on, and how each was checked:

- **"Let a failed main-branch repair retry itself"** (`41b0c16234`). Retry
  eligibility looked for the opening workflow only as `initial`, so
  main-branch repair Jobs were refused forever as `initial_not_run`. The fix
  adds `OPENING_TRIGGER_KINDS = initial, main_branch_repair`.
  - *Relied-on invariant:* every Job kind that goes through the generic retry
    (`RetryWorkflowEligibility`, `RetryJobs::Mode`) opens with one of those
    kinds.
  - *Checked:* every caller of `RetryWorkflowEligibility` and every Job kind.
    `external_pr` retries through its own `ExternalPrIngestRetryEnqueuer` and
    never reaches this check. In production (read-only), the opening kinds of
    failed Jobs are only `initial` (issue, direct) and `main_branch_repair`
    (direct).
  - *Assumption to keep:* a plugin Job kind that opens with its own Workflow
    and uses generic retry would hit the same refusal. Deriving the opening
    workflow as the Job's first Workflow would remove the list.
- **"Refuse to retry an attempt a newer success already replaced"**
  (`b57d999ab1`). Implementation-retry preflight now refuses a source that
  `superseded_by_newer_successful_publication?`.
  - This is the *manual* path. It differs from the automatic rule F90 unified
    (`Workflows::AutoRetrySupersession`), but they govern different decisions.
  - The reconciler's stale-retry repair only targets Workflows carrying
    `auto_retry_attempt_id`, so the difference cannot produce the
    launch-then-cancel loop.
- **"Do not fail a workflow over a grader whose failure it advances past"**
  (`98ee966907`). `orphaned_failed_step` now skips advance-on-failure kinds.
  - This closes part of NY26: the reconciler no longer hard-fails a Workflow
    over a grader-style failure that the live dispatch would have advanced
    past.
  - NY26 remains for the try-branch and in-place infrastructure-retry outcomes.
- **The others** are local, and none touches an invariant proved on this
  branch:
  - the main-repair preflight graders and simulator database path;
  - the `list_recent_workflows` worker budget;
  - retry operator guidance;
  - the grader-failure attribution prompt;
  - the publication-resolved retry headline;
  - replacing Syrus's own earlier PR branch;
  - e2e menu lookup;
  - GitHub Actions log parsing;
  - leaving failed graders to their collector.

**Post-rebase checks:**

- the CI-only reconciler, executor and resilience specs: 351 examples, 0
  failures;
- `spec/jobs`, `spec/services/workflows`, the retry specs and `spec/models`:
  3,342 examples, 0 failures.

---

## M43. Which blocked reasons a started landing can hold the slot on — audited, one design question

**Scope.** DOC-44 scheduling, the coverage item `gates-starvation-free`,
following F92.

**The reasons a started landing can block on.** At a phase boundary, the base
unit gates are `ActiveWorkLock`, `MainBranchHealth`, `ProviderAvailability`,
`ManualPause` and `AdmissionControl`. The lifecycle adds
`agent_cannot_proceed` (F92). Grouped by how they clear:

| Clears | Reasons | Landing slot |
|---|---|---|
| On its own, with a scheduled recheck | `active_work_lock`, `provider_availability`, `admission_control`, `resource_safety` | kept; the unit really is next |
| When main is repaired, by the main grader and repair work | `main_branch_health` | kept; while main is broken no landing proceeds anyway |
| Only when someone acts | `ci_repair_disabled`, `no_capable_worker`, `agent_cannot_proceed` | released |
| Only when someone unpauses | `manual_pause` | **kept** |

**Open: a manual pause of a started landing (NY27).** NY7 settled the
pre-start case: any block before the first Run gives the slot back,
`manual_pause` included. A pause after the landing started still keeps the
repository's `landing:` lock. So pausing one landing Job stops every other
approved Job in that repository from landing until it is unpaused.

Releasing it would follow the allowlist's own rule, since a paused unit is not
about to run. The cost is that, on unpause, the Job may wait for another
landing to finish. `ensure_active_locks!` then raises `LockConflict` and the
unit waits its turn. Whether pausing a Job should also hold the repository's
queue is a design decision.

---

## M42. A landing Job whose units are all blocked externally is returned to approved — audited, no bug

**Scope.** DOC-44 landing, the partial coverage item `stranded-landing-job`: "A
Job stays in landing although every unit landing it is blocked externally."

**The gap.** `WorkUnit#block!` on an externally cleared reason gives back the
landing slot (M41), but it does not move the Job: the Job stays in `landing`.
After F7, the only such reason left for landings is `ci_repair_disabled`. A
Job parked on it reads as landing, and nothing lands until an operator
re-enables CI repair. Separately, `Launcher.start!` lifts the Job to landing
(`ensure_landing_job_state!`) before `Scheduler.evaluate!`, so a gate that
blocks at start can leave the same shape.

**Covered by an auto-repair.** `classify_stranded_landing_job` reports a Job in
`landing` whose landing units exist and are *all* blocked on an externally
cleared condition (`externally_blocked?`). It is safe to auto-repair:
`defer_stranded_landing_job` returns the Job to `approved`. The landing queue
then re-admits it once the condition clears, instead of leaving it apparently
in flight. If any landing unit is not externally blocked (it is running, or
waiting on something that clears by itself), the Job is legitimately landing
and is left alone.

Production (one week, read-only): zero `stranded_landing_job` detections; 3
`landing_job_without_active_runtime_work`, all skipped because the Job had
already left landing.

---

## M41. A blocked landing holds the repository slot only while it is about to run — audited, no bug

**Scope.** DOC-44 landing, the partial coverage item
`externally-blocked-landing-slot`. F7 made `no_capable_worker` landings fail
and release instead of blocking. Two reasons remained unproved:
`ci_repair_disabled`, and the `AutoRetryBackoff` re-lock.

The repository landing slot (`landing:` lock) is the mutex every landing path
checks. A blocked unit that keeps it stalls every other landing in the
repository.

**`WorkUnit#block!` releases the slot in two cases:**

- **The reason cannot clear by waiting** (`EXTERNALLY_CLEARED_BLOCKED_REASONS`:
  `ci_repair_disabled`, `no_capable_worker`). It clears only when an operator
  changes the configuration or the fleet, so the unit is not about to run and
  gives the slot back at once.
- **The landing has not started its first Run** (`prestart_landing_block?`).
  Decision NY7, proved in `PrestartSlot.lean`, says a prestart block gives the
  slot back whatever the reason.

Only the `landing:` lock is surrendered. Job- and Epic-scoped locks stay held,
because they still correctly stop a second attempt at the same work.

**`auto_retry_backoff` keeps the slot on purpose, and only for a bounded
time.** It is a self-clearing reason: the unit has `blocked_until` set and
really is next. Releasing would let a later landing cut ahead of a landing
that is waiting out a backoff. The slot is held for at most the backoff
interval. The number of backoffs is bounded by the cumulative auto-retry
budget per (job, provider, classification) (`auto-retry-bounded`, F44/F45),
so the slot cannot be squatted indefinitely.

---

## M40. A requested WorkIntent without a unit is dormant, not stuck — audited, no bug

**Scope.** DOC-44 ownership, the partial coverage item
`requested-intent-without-unit`. F42 found that both of its classifiers return
nothing unless the Reconciler is invoked with a `work_intent_id`, and no
production caller passes one, so the state is never detected. The question
here is whether that matters.

**Nothing acts on such an intent by itself.** The production readers of
`requested` intents are the repair executor's guards and
`WorkUnit#reactivate_work_intent!`. No background process scans requested
intents and launches work from them. "Materializing" one only means
`Launcher#find_or_create_intent!` reusing it when a later launch passes the
*same* idempotency key (the rebase, merge-state and stale-branch pollers,
and auto-retry). That launch then creates the unit under the intent lock
(`intent.lock!` when a key is present), so the reuse is serialized.

**So the record is dormant.** A requested intent with no unit:

- holds no lock, since locks belong to units;
- blocks nothing, since admission gates key on units and Jobs;
- is either reused by the next keyed launch for the same work, or stays inert.

Whatever work it stood for is still observed where it matters: through the
Job and Workflow states that the Job-level classifiers check, including a
running Job with no work (F88), a queued Workflow with no first Run, and a
stalled intake.

The undetectable classifier is therefore a monitoring gap, not a liveness
gap. Wiring a `work_intent_id` into a production Reconciler caller would make
the count visible, but no Job waits on these records.

---

## M39. No WorkUnit state write bypasses the lock release — audited, pinned

**Scope.** DOC-44 ownership, the partial coverage item
`terminal-unit-holds-locks`. `Proofs.lean` `inv_no_terminal_locks` proves that
no terminal unit holds an active lock under the modelled transitions. The gap
was callback-skipping `update_columns` writers outside the model.

**Audit.** The two terminal transitions release locks inside the same
transaction as the state write:

- `WorkUnit#mark_terminal!` (`work_unit_locks.active.find_each(&:release!)`);
- `WorkUnit#preempt!`.

Lock *acquisition* is an INSERT against a unique key (M25), so release is the
only half that a raw write could skip. A search of `app/`, `lib/` and the
plugins' `app/` and `lib/` finds no production write of a WorkUnit's state
through `update_columns`, `update_column` or `update_all`. The only one is the
simulator's scenario loader, which builds fixtures. So the model's transitions
are the only ways a unit becomes terminal, and the proof covers the code.

**Pinned.** `spec/architecture/work_unit_terminal_writes_release_locks_spec.rb`
fails on any callback-skipping write of WorkUnit state outside the simulator.
Its pattern was checked against the loader's real line, which it matches, so a
production write would be caught.

---

## M38. Work launched on a closed Job is cancelled at start and its intent retired — audited, no bug

**Scope.** DOC-44 job state, the partial coverage item `closed-job-active-unit`:
"A closed Job still has an active job-scoped WorkUnit without a Workflow."
The note asked for the launch to check that the Job is open under the same
lock as the close.

**`WorkUnits::Launcher.instantiate` does not check that the Job is open.**
Closure is enforced where work would *run*:

- `StepDispatcher.start_workflow` cancels a Workflow whose Job is closed
  (`cancel_unstartable_closed_job_workflow!`, reason `job_closed`), unless it
  is a redeploy on a closed Job;
- `enqueue_next_runnable_steps!` applies the same check at every step
  boundary (`job_closed_for_execution?`);
- `classify_closed_jobs_with_active_runtime_work` auto-cancels anything left
  active under a closed Job.

So a launch that races a close produces at most a queued unit, and that unit
is cancelled the moment it would start. No Step runs for a closed Job.

**The intent does not relaunch.** Cancelling that Workflow preempts its unit
with reason `job_closed`. That string is `JobClosure::CANCELLED_REASON`, which
is in `WorkIntents::TerminalUnitSync::SUPERSEDING_CANCEL_REASONS`, so the
unit's intent is cancelled instead of left `requested`. That rules out the
F27-shaped loop of a requested intent re-materializing on a closed Job.

**Left as is.** `closed-job-open-intent` stays partial: member-scoped (Epic or
merge-train) intents outlive the close of a single member by design.

---

## M37. The last queued-Run recoveries: wedged claims, cached grader failures, pre-start crashes — audited, no bug

**Scope.** These are the three remaining open DOC-44 runs and queue items:
`queued-run-wedged-or-stale-claim`, `queued-grader-collect-cached-failure`
and `queued-run-failed-execution`. All three are liveness questions that
depend on workers and the queue (class c, or class a with infrastructure
causes).

**Wedged or stale claim.** `wedged_queue_claim?` matches a SolidQueue row
claimed for longer than `WEDGED_QUEUE_CLAIM_AFTER` while the Run never
started. The repair is the same `ReenqueueRun` as for a dead resume queue
(M32), done under the Run lock. It deletes the stale queue rows *before*
dropping affinity, so no old resume job can stamp the storage key back while
the repair runs. The replacement then goes to the general queue. As its
comment notes, routing would otherwise hand the Run straight back to the
still-heartbeating storage key it is stuck on, and the repair would loop. It
terminates in one step.

**Cached grader failure.** When a queued `grader_collect` Run belongs to a
Workflow whose grader conclusion for this commit is already cached as failed
(`GraderConclusionCache.failed_for_workflow?`), the classifier reports
`queued_grader_collect_cached_failure`, whatever queue the Run is stuck on.
The repair, `mark_cached_grader_collect_failed`, fails the Run from the cached
conclusion instead of replaying graders whose result is known. Its spec pins
that writing the diagnostic cannot double-insert. Every other queued-Run
repair refuses to re-enqueue when a cached failure exists, so the two cannot
disagree.

**Pre-start crash.** RunJob failures before the Run starts are
infrastructure: lock-wait timeouts and SolidQueue process pruning, from the
read-only production analysis of 61 executions. They leave the Run queued
with a failed queue execution. The reconciler re-enqueues it, which is the
intended recovery. Step failures that RunJob re-raises *after* handling them
are finished Runs, not pre-start crashes.

This closes the runs and queue area, apart from the NY26-dependent bound
`worker-loss-bounded-recovery`.

---

## M36. Stalled intake classification is retried, bounded by real attempts — audited, no bug

**Scope.** DOC-44 job state, the coverage item `stalled-intake`: "A Job stays
in triaging because its classification job vanished." The fault is a lost
token, and the plan asks for bounded retries rather than prevention.

**Detection.** `classify_stalled_classifier_pending_jobs` covers triaging Jobs
of a classifiable kind with no classification activity for
`CLASSIFIER_PENDING_STUCK_AFTER` (activity is the later of the last attempt's
`started_at`, `updated_at` and `created_at`). It applies only while retries
remain:

- a `classifier_pending` Job needs `classifier_attempts < MAX_CLASSIFIER_ATTEMPTS`;
- a `classifier_uncertain` Job needs `classifier_retry_available?`.

It is safe to auto-repair.

**Repair.** Under the Job lock, `ReclassifyStalledIntake` rechecks the state,
the kind and the attempt cap. It moves an uncertain Job back to pending, then
enqueues `ClassifyIssueJob` in the same transaction, so a blocked enqueue rolls
the transition back. Each repair is audited as a `StateTransition`.

**The bound.** Only a real `IngestionClassifier` invocation advances
`classifier_attempts`, and every real run does so, retryable failures
included. So a classifier that keeps running is cut off at
`MAX_CLASSIFIER_ATTEMPTS`, and the triage decision then hands the Job to a
person.

A queue job that is *lost* never advances the counter, so the cap does not
bound those re-enqueues. They are still harmless:

- `ClassifyIssueJob` has `limits_concurrency to: 1` per Job, so duplicates
  queue behind each other instead of running together;
- `ClassifyIssueJob` refuses to run unless the Job is still
  `classifier_pending`, so every duplicate after the first real classification
  is a no-op.

**Refinement worth considering, not a bug.** The repair does not touch any of
the timestamps the classifier measures staleness from. A Job whose
classification is merely *slow* (queued behind a backlog past the threshold)
is therefore re-enqueued on every reconciler pass until it runs. Each copy is
serialized and becomes a no-op, so the cost is a queue of blocked executions,
not wrong work. Stamping the enqueue time onto the activity that staleness is
measured from would limit it to one re-enqueue per threshold.

---

## M35. A Workflow paused at a phase boundary by admission resumes — audited, no bug

**Scope.** DOC-44 start blocks, the coverage item
`resource-admission-start-block`: "A Workflow paused at a phase boundary is not
resumed after its admission recheck."

**Two layers.**

- **The gate's own recheck.** A phase-boundary admission or resource block
  goes through `Launcher.schedule_blocked_recheck!`, which enqueues
  `WorkflowPhaseAdmissionJob` at the gate's `retry_at`, or after
  `START_BLOCKED_BACKOFF`.
- **The overdue safety net.** If that recheck is lost, `classify_start_blocks`
  reports `resource_admission_start_block`. It does so only for a *running*
  Workflow whose recorded block has a `phase_step_id`, whose recheck time has
  passed (`start_blocked_check_due?`), and whose reason is an admission or
  resource reason (`WorkflowAdmissionCapacityWakeup.admission_or_resource_reason?`).
  It is safe to auto-repair, through `resume_deferred_phase`, which goes back
  through the same gates.

The repair re-runs the gates instead of bypassing them. So it can only resume
a phase that admission now allows, and otherwise re-blocks with a fresh
recheck. Capacity freeing up also wakes blocked work directly
(`WorkflowAdmissionCapacityWakeup`).

---

## M34. Provider pauses only pause admission, and recovery re-admits the paused work — audited, no bug

**Scope.** DOC-44 start blocks, the coverage item `provider-pause-readmits`:
"Provider unavailability only pauses admission, and recovery re-admits exactly
the paused work." This is liveness under fairness.

**Pause.** `WorkUnits::Gates::ProviderAvailability` asks
`ProviderAvailabilityPause` for a decision:

- On *pause* it blocks the WorkUnit with `provider_availability` and the
  pause's `retry_at`.
- On *failover* it re-pins a Workflow that has no Runs to the selected
  provider, under the Workflow lock, and passes.

No Run is failed and no Step is touched. The work only waits.

**Two independent ways back:**

- **Recheck.** `Launcher.schedule_blocked_recheck!` enqueues
  `WorkflowPhaseAdmissionJob` at `retry_at`, or after `START_BLOCKED_BACKOFF`.
  This covers first admission and phase boundaries of running Workflows alike.
  That matters because `provider_availability` is a pause reason, so the
  reconciler treats it as a deliberate wait and leaves it alone.
- **Wake-up (fast path).** `ProviderAdmissionWakeup` runs when the provider
  recovers. It restarts exactly the queued Workflows on that provider that have
  no Runs and whose unit is blocked on `provider_availability`, skipping any
  whose circuit is still open. It also releases pending auto-retries on the
  provider to the reconciler.

So paused work is re-admitted at the latest by its own recheck. The wake-up
only shortens the wait. A Workflow blocked on a provider its Job no longer
resolves to is relaunched by `StaleProviderRelauncher`.

**Simulations**, all passing:

- `provider_usage_pause_then_resume`;
- `provider_auth_pause_then_resume`;
- `provider_switch_relaunches_blocked_work`;
- `codex_overload_initial_retries`.

---

## M33. A finished Workflow's workspace is never deleted under live work — audited, no bug

**Scope.** DOC-44 steps and workflows, the coverage item
`terminal-workflow-live-processes`: "A finished Workflow still has a running
OS process or a step that only looks running". The safety side is that
cleanup never deletes a workspace something may still be using.

**What counts as live.** `Workflow#live_descendants?` is true for any of:

- an active Run;
- a *projected* running Step;
- a running `SpawnedProcess` recorded for the Workflow or any of its Runs.

It is deliberately conservative. A Step that only looks running through its
projection still counts.

**Every deletion path is guarded:**

- `Workflow#cleanup_workspace!` defers while `cleanup_blocked_by_active_descendants?`
  holds.
- `WorkflowWorkspace.cleanup_for` re-checks the same predicate. It also takes
  the workspace's exclusive file lock, and defers if a live process holds it.
  It defers again if the Workflow became active during cleanup.
- The retention sweep `WorkflowWorkspacePruneJob#filesystem_sweep` sends every
  directory whose Workflow still exists through `cleanup_workflow` and so
  through `cleanup_for`.
- The only direct `rm_rf` is for directories whose Workflow record no longer
  exists. No DB-tracked Run, Step or `SpawnedProcess` can reference those.

**The stuck case is reported, not forced.** A terminal Workflow whose live
descendants never clear (an orphaned `SpawnedProcess` heartbeat, or a
projection-only running Step) is reported as
`cleanup_blocked_by_active_descendants` for operator review. It is reachable
only when no persisted Step or Run is active. Cleanup stays deferred rather
than deleting under a process that might be alive. Whether such a process is
really dead depends on `SpawnedProcess` liveness, which is outside this model.

---

## M32. Runs stranded on a dead worker's resume queue are rerouted once — audited, no bug

**Scope.** DOC-44 runs and queue, the coverage item
`queued-run-dead-resume-queue`: "A queued Run sits on a resume/worker queue
that no live worker consumes." This is a liveness question that depends on
workers (class c).

**Detection.** `classify_queued_runs` reports `queued_run_on_dead_resume_queue`
only when both hold:

- none of the Run's SolidQueue rows can progress;
- a ready row sits on an explicit worker or storage queue with no live
  consumer (`dead_worker_queue?`).

A cached failed grader conclusion takes the separate cached-failure path
instead.

**Repair, which terminates in one step.** `ReenqueueRun` rechecks under the
Run lock:

1. the Run is still queued;
2. the Workflow is still active;
3. no auto-retry is pending;
4. no cached failure blocks it;
5. the affinity queue is still stranded (`remove_stranded_affinity_queue`).

It then clears the Workflow's dead resume affinity and re-enqueues with
`ignore_workflow_affinity`. So the replacement goes to the general queue and
the workspace is re-prepared there. Routing cannot hand the Run back to the
dead storage queue, because the affinity that pointed at it is gone. Each
stranded Run is therefore repaired once, not looped.

**Production** (read-only): 60 applied re-enqueues, all in four windows on
2026-11-19 while worker pods were being replaced. That is the intended
recovery. Handing Runs off when a pod drains, instead of waiting for the
reconciler, belongs to the graceful-deploy work.

---

## M31. Checkpoint-backed retry of a blocked Workflow is gated on proof, not age — audited, no bug

**Scope.** DOC-44 retries, the coverage item `checkpoint-backed-blocked`. A
blocked Workflow on a failed Job has a verified checkpoint and could be
retried. This is a recovery opportunity, not a bad state. The safety side is
that a retry from the checkpoint never resumes past work that is still live or
semantically failed.

**`BaseRefreshRetryEligibility`** admits a blocked source only if all of these
hold:

- it has no active Runs;
- the Job has no live WorkUnit ownership or retained mutation locks;
- *every* failed Run carries a structured, retryable
  infrastructure classification (`disk_full`, `storage_unavailable`,
  `worker_died`, `worker_died_under_resource_pressure`). Anything semantic or
  ambiguous goes to operator review.

It then requires a published `RunCheckpoint` whose provenance matches the Job,
the Workflow and the checkpoint's Run, with a commit SHA and a durable remote
ref. That ref must resolve to exactly that SHA right now, with `max_age: 0`,
and the Job's effective base must resolve. An unresolvable checkpoint or base
is refused. The existing negative fixture pins the case of a dirty grader
barrier.

So a blocked Workflow is only ever retried from a checkpoint that is provably
the work it recorded, onto a base that exists, with nothing else live.

---

## M30. Landing start-blocks always recheck or fail — audited, no bug

**Scope.** DOC-44 landing, the coverage item `landing-start-blocked`: "A
landing Workflow is blocked before start (main repair, transient gate)." The
liveness question is whether every block is rechecked, and whether its marker
outlives the gate.

**Every start-block on a landing Workflow either fails it or schedules its own
recheck** (`StepDispatcher.start_workflow`):

- **Fail explicitly.** A failed dependency, an unresolved stack base, and a
  Job-level block each call `fail_unstartable_landing_workflow!` with the
  reason. The landing never sits waiting on them.
- **Record and recheck.** The provider, repository-preflight and Epic-wide
  locks, the landing-queue pause, main health, and urgent work each record the
  block, then enqueue `WorkflowPhaseAdmissionJob` after
  `START_BLOCKED_BACKOFF`. The comments on the main-health and urgent gates
  record that their release wakes nothing else, which is why they look again
  on their own backoff.
- **Pause.** A manual pause is a deliberate wait that `unpause!` resumes.

**The marker is a cache of the gate.** Each gate calls `clear_start_blocked!`
for its own reason the first time it passes. So a `start_blocked_reason` left
behind after the gate cleared lasts at most until the next recheck.
`warn_if_stuck_queued` surfaces a block that persists.

---

## M29. A cancelled retry-until barrier never blocks its tail for long — audited, no bug

**Scope.** DOC-44 steps and workflows, the coverage item
`cancelled-barrier-blocks-tail`. The invariant: "a queued Step with a
dependency cancelled without runs is itself cancelled". The hazard is a
cancellation made with the cascade suppressed
(`Step.suppress_cancel_cascade`, used by `Workflow#cancel_active_descendants!`
and the loop-exit paths), on a Workflow that is later reopened.

**Covered by two auto-repairs, both scoped to a running Workflow** (only a
running Workflow can have a queued tail waiting on a barrier):

- `cancelled_retry_until_barrier_blocking_tail` (`classify_queued_steps_without_runs`)
  covers a queued Step outside the loop whose latest unsuperseded
  retry-until barrier is cancelled with *no* Runs.
  `ReopenCancelledRetryUntilBarrier` requeues the barrier and creates its Run,
  once its own dependencies are settled.
- The terminal-workflow cleanup revival covers a cleanup-cancelled Step that
  *had* started a Run. After the Workflow is reopened, the reconciler and
  `DeferredPhaseResume#revive_cancelled_tail_after!` revive the earliest such
  Step, so dispatch can pass it.

So whichever path left the barrier cancelled, the tail is released on the next
reconciler pass instead of waiting forever. Neither repair requeues a barrier
whose Runs exist or whose dependencies are unsettled, so neither can start
work out of order.

---

## M28. Finished infrastructure Jobs are closed — audited, no bug

**Scope.** DOC-44 infrastructure Jobs, the coverage item
`completed-infrastructure-job`: "An infrastructure or main-branch-repair Job
finished its work but stays open."

**Hooks.** Infrastructure kinds manage their own Job lifecycle, and generic
propagation skips them.

- `MainGrader.after_success` / `after_fail` close the anchor Job.
- `Deploy.after_success` / `after_fail` close it with `DEPLOY_CLOSURE_REASON`.
- `MainBranchRepair.after_success` closes it with `preflight_passed` or
  `preflight_inconclusive`.
- None of the three defines `after_cancel`. For `main_branch_repair` there is
  no `after_fail` either: generic `fail!` drives that Job to `failed`.

**Safety net.** `classify_completed_infrastructure_jobs` covers any open Job
whose latest Workflow is terminal, cancelled included. It auto-repairs
infrastructure Jobs (`main_grader`, `deploy`), and a `main_branch_repair` Job
whose Workflow succeeded with `preflight_passed` and opened no PR. So a skipped
or raising hook, or a cancelled Workflow, closes on the next reconciler pass.

**Not auto-closed, by design.** A cancelled or failed `main_branch_repair`
Workflow leaves its Job open or failed. While that Job blocks main health,
`stuck_main_branch_repair_job` surfaces it as critical for operator review
(the by-design item `stuck-main-branch-repair`).

Production (read-only): 2 `close_completed_infrastructure_job` executions,
both skipped because the Job had already closed itself.

---

## M27. Epic-blocked Jobs are released once the Epic releases them — audited, no bug

**Scope.** DOC-44 Epics, the coverage item `epic-blocked-job-releasable`: "A
Job stays blocked by its Epic although the Epic now releases it." This should
be transient at most.

**Inputs of `Epic#releases_jobs_for_execution?`.** It holds when the Epic is
in progress (or done) and `execution_dependencies_ready?` holds. That in turn
means every upstream Epic is done, or the Linear early-execution policy says
the dependencies are ready. The Linear policy depends on:

- the feature flag;
- a single same-repository upstream Epic that is also linear;
- every upstream Job implemented, approved, landing or succeeded, with a
  branch, a PR and a head SHA.

**Each input change wakes the release:**

- the Epic starting (`start` and `set_state(in_progress)`) runs
  `unblock_child_jobs!`;
- an upstream Epic's state change runs `refresh_dependent_epic_auto_states`
  (`after_update_commit`), and through `refresh_auto_state!` reaches
  `release_child_jobs_if_ready!`;
- adding, changing or removing a dependency edge runs
  `EpicDependency#refresh_dependent_epic` (`after_commit`);
- an upstream Job becoming implemented runs
  `Job#refresh_execution_ready_dependent_epics`. Its head SHA is derived from
  its Runs and is already present by then.

**The one unwatched input is the flag.** Turning on
`early_epic_dependency_execution` wakes nothing. Even so, the Job is not
stuck: `classify_releasable_epic_blocked_jobs` tests the *same* predicate
(`releases_jobs_for_execution?` and `dependencies_satisfied_for_execution?`),
and is safe to auto-repair whenever the Job can still be released. So any
missed wake-up is released on the next reconciler pass.

Production (read-only): no `releasable_epic_blocked_job` repairs in the
retained history.

---

## M26. A failed Step on a queued Workflow — dispatch audited, one design question

**Scope.** DOC-44, the coverage item `queued-workflow-with-failed-step`:
"An unsuperseded failed Step with no live work implies the Workflow is
terminal or a loop continuation is pending."

**The live dispatch is total.** `StepDispatcher#fail!` ends every branch with
the Workflow terminal, new live work, or a pending loop continuation:

- a step kind that advances on failure (`:advance`) advances;
- a loop-iteration kind continues the loop, stops it, or hard-fails;
- a run that died of retryable infrastructure is retried, bounded by
  `INFRASTRUCTURE_STEP_RETRY_LIMIT`;
- a try branch is taken;
- otherwise the Workflow hard-fails.

So the state is reachable only if the cascade itself is lost, for example an
exception in the Step's `after_update_commit`. In that case
`queued_workflow_with_failed_step`, and its running twin
`running_workflow_with_failed_step`, auto-repair it.

**Open: the repair does not replay the cascade (NY26).** The reconciler offers
two repairs. A pending loop with budget remaining gets
`StepDispatcher.fail_from(step)`, which is the cascade itself. Everything else
gets `fail_workflow_from_failed_step`, which calls `Workflow#fail!` directly.
That skips three of the cascade's outcomes:

- advance-on-failure kinds;
- try branches;
- the in-place retry of a run classified as retryable infrastructure.

A failed `test_plan` Step whose run was classified `worker_died` illustrates
it. A first version of `failed_step_with(retryable: true)` showed the cascade
retrying the Step, while the repair failed the Workflow, and with it the Job.
The existing spec "fails a running workflow that already has a failed step and
a queued tail" pins the repair's behaviour on purpose, with a retryable
`agent_resume_unavailable` run: fail the Workflow "and let the normal
failed-step retry path take over".

The two recovery paths disagree about the same state, and choosing which is
right is a design decision, so the code is unchanged. This also bears on
`worker-loss-bounded-recovery` ("Worker or storage loss never fails a Job by
itself").

---

## M25. Row-lock order across the engine — counterexample, design question

**Scope.** DOC-44 concurrency, the coverage item `lock-order-acyclic`. Every
transaction that takes FOR UPDATE locks on more than one of these models was
traced one or two calls deep: Job, Workflow, Step, Run, WorkUnit, WorkIntent,
WorkUnitLock, Epic, AppSetting, User and Repository. The traced forms are
`lock!`, `with_lock`, `.lock` and `lock(true)`.

**Ground rules.**

- `Workflow#start` and `Run#start` lock the Job in a `before` callback
  (`workflow.rb:103`, `run.rb:176`).
- `Workflow#set_artifact!`, `#delete_artifacts!` and `#request_job_closure!`
  take the Workflow lock.
- `WorkflowCancellation` locks the Workflow, then its active Steps, then the
  WorkUnit.
- Lifecycle propagation runs in `after_update_commit`, so it does not nest
  inside the caller's locks.
- WorkUnitLock rows are inserted against a unique key, never locked.
- `AppEvents.next_sequence` runs after the outermost commit, so it is not part
  of any cycle (lead L2's User row is refuted).
- `GraderFanoutAdmission` does hold the AppSetting lock while it creates grader
  Runs. This is a long holder, not a cycle.

**Counterexample.** The recorded graph has cycles. The clearest one involves
the same records from two plausible concurrent actions:

- An operator **cancel** or force-transition of a landing Job runs
  `Job#cancel_active_runs_and_close!`. It locks the Job (`job.rb:1365`), then
  `WorkflowCancellation` locks each active Workflow
  (`workflow_cancellation.rb:51`).
- The **landing queue's** `release_blocked_landing_slots!` locks that Job's
  queued landing Workflow (`landing_queue_processor.rb:757`), then its Job
  (`:759`).

Under InnoDB, one of the two is rolled back with `ActiveRecord::Deadlocked`.
The other inversions are:

- **Run ↔ Job.**
  - RunJob takes Run → Job.
  - `PlannedExecutionOverrides` takes Job → Run.
- **Run ↔ Workflow.**
  - The RepairExecutor requeue and `RepairQueueAffinity` take Run → Workflow.
  - `PlannedExecutionOverrides` takes Workflow → Run.
- **Epic ↔ Job.**
  - `MergeTrainDispatcher` takes Epic → Job.
  - The merge-train rebuild in `RetryFailedStepEnqueuer` takes Job → Epic.
- **Workflow → Job**, more generally: any path that holds a Workflow lock and
  calls `workflow.start!` takes it, because of the `before { job.lock! }`.
  Examples are `TerminalWorkflowSync` called without a Job lock, and
  auto-merge `record_run_failure!`.

In production (read-only, 7 days) no deadlocks occurred, but there were 33
lock-wait timeouts on hot rows. So the cycles are latent, not yet observed.

**Model.** `LockOrder.lean` encodes the audited edge set:

- `observed_has_cycle`: the observed graph has cycles;
- `job_workflow_inversion`: the two-transaction witness;
- `exactly_four_inversions`: under the proposed order
  AppSetting → Epic → Run → Job → WorkIntent → Workflow → Step → WorkUnit →
  User, exactly four edge kinds are wrong (Job → Run, Job → Epic,
  Workflow → Job, Workflow → Run). The hot RunJob Run → Job path keeps its
  order.

The model proves a property of the recorded graph, not of the code. The edges
come from this audit.

Not counted: plain UPDATEs also take InnoDB row X locks. Paths that UPDATE a
Job inside a Workflow lock without FOR UPDATE (for example
`WorkflowCancellation`'s Job writes) add implicit Workflow → Job orders. The
proposed order makes those consistent too.

**Open: NY25.** Fixing this is choosing a global order and changing the
inverted sites to follow it, which is a design decision.

---

## M24. Desktop image cleanup and reboot resume — audited, one design question

**Scope.** DOC-44 Phase 7:

- "Cleanup never deletes the active or recovery image", "Old images are
  removed only after the new backend is healthy", and "Failed backend update
  retains the current or rollback-relevant image";
- "Reboot recovery resumes only the intended channel and phase".

**Cleanup holds for the active image.**
`removeSupersededSyrusImages` runs only on the update path, and only after
`ok && backendHealthy()` (F80 audit). The pure filter `supersededSyrusImages`
removes a ref only if all of these are true:

- the ref has a Syrus basename;
- it is in the *same repository* as the pin;
- it has the *same tag channel* as the pin (the rule F79 made both callers
  share);
- it is neither the pin nor referenced by a running container.

Removal is a plain `docker image rm` without `-f`, so any image a container
still references, running or stopped, refuses and stays. Two cases fail
safe and remove nothing:

- there is no pin;
- the pin is a digest (`repo@sha256:…`). Its "repository" then matches no
  listing.

**Open: the previous image is the only local rollback target (NY24).** After
a *healthy* update, every same-channel sibling of the new pin is removed,
including the image that was running a minute earlier. If the new version
then misbehaves after its health gate (a data migration or runtime bug), the
only rollback is re-pulling the old multi-GB image, which may be impossible
offline. Keeping it costs one image, about 7.6 GB.

**Reboot resume holds.** The Windows RunOnce value name is per channel
(`SyrusResumeSetup` / `SyrusResumeSetupTest`), and it launches the running
channel's own executable. The resume flag (`onboardingResumeLocal`) lives in
the channel-specific settings store. `clearRebootResume` removes only this
channel's value. So a reboot resumes exactly the interrupted channel, and the
local flow is the only phase that arms it.

---

## M22. Diff review endpoints and per-job review state — audited, no bug

Main's "Keep diff review endpoints independent across versions," "Keep diff
review range endpoints independent," and "Isolate review state across cached
jobs."

- **Endpoints are compared exactly.** The client keys the range query on both
  SHAs (`["jobs", id, "review_source_diff_range", base, head]`) and sends both.
  `App::JobSourceDiffPayload` resolves exactly the requested `base` and `head`,
  and under `explicit_selection?` it skips the stored-version fallback. So an
  incomparable or unresolvable pair surfaces `diff_error` instead of a diff of
  some other pair, which is what lets the selector keep FROM and TO
  independent without lying about what is shown.
- **One job's review data never shows under another.** The source-diff query
  uses `placeholderData: keepPreviousData`, which carries data across a key
  change within one mounted observer. Both mounts are keyed by job: the
  desktop `ReviewWorkspace` uses `key={payload.job.id}` in `JobDetail.tsx`,
  and the mobile `MobileReviewCard` uses `key={job.id}` (added by that
  commit). Each job therefore gets a fresh observer with no previous data,
  and the version list additionally checks `job_id === jobId`.

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

Later commits, checked through main `cb5b006575` (two merge trains):

- The backup and disaster-recovery epic: retention, replication leases and
  verified-copy preservation hold (M20, NY21). Recovery preflight blocks
  known incompatibilities but only warns on unknowns (M21, NY22). Capture,
  capacity admission, partial cleanup and the S3 destination are covered by
  their own specs. Their macOS-only spec failures were fixed while merging.
- The diff review and mobile review train: endpoint independence and per-job
  state isolation hold (M22). The remaining commits are layout and
  accessibility only.

- A commit already inside that range, which built the coworker tool surface
  from enabled plugins only: the invariant (a per-process memo depends only on
  static inputs) failed. It made the full suite order-dependent and put 38
  wrong rows in the MCP catalog. F131, fixed on main in `8f3fdf0ac1`.

- The Runtime Image Service epic (contracts, OCI registry provider, worker
  pull cache, publishing, retention and reconciliation). The worker cache's
  invariant (an acquired image is never removed) failed when a holder
  outlived its lease: F132, proved in `CacheLease.lean`. The eviction-claim
  takeover is safe by its own argument: a claim is taken over only after
  `claim_ttl`, which the constructor requires to exceed the engine's remove
  timeout, and every write is scoped to the claim token. The terminal image
  states (revoked, deleted) are covered by their own specs.

Checked through main `d946eda665`. Each loop iteration continues from there:
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

## Lead L4: a running rebase whose next Step never got a Run, for 22 days (production, read-only) — closed by F89: a deliberate operator pause

Found while working the coverage item `job-state-vs-active-workflow-kind`.
The `/admin/stuck` list shows one `job_workflow_state_drift`: a `failed` Job
that still has a `running` rebase Workflow. The evidence:

- **The storm.** Five rebase Workflows on the Job ran in about 15 minutes.
  Each one ran `auto_rebase` → `agent_rebase` (both succeeded) →
  `force_push`, which failed with `StepFailed`. That ends in
  `enforce_workflow_runaway_limits!` setting
  `runaway_protection = too_many_failed_workflows` and force-failing the
  Job.
- **The stall.** The last Workflow started 3 minutes after the previous one
  failed. Its `auto_rebase` and `agent_rebase` succeeded, but its `force_push`
  Step has been `queued` with no Run ever since. The Workflow is still
  `running`.
- **Not the gate.** `WorkIntents::Gates::RunawayProtection` gates only
  admission of new intents, so it does not explain a Step that never got a
  Run inside an already-running Workflow.

Open questions for the next pass:

1. Why did step advancement after `agent_rebase` not create the `force_push`
   Run?
2. Why does no reconciler classifier repair "running Workflow, next Step
   queued with no Run"? The existing `queued_workflow_without_first_run` only
   covers a queued Workflow's first Step.
3. Should the drift classifier treat `implemented` plus an active
   non-approval-blocking follow-up (rebase), whose start deliberately leaves
   the Job `implemented`, as legal? Today it reports it as drift.

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
