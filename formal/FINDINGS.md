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
