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

## Open questions for review

- **Q1. A landing parked mid-run gives up the landing slot.** `block!` with
  `no_capable_worker` releases `landing:*` even while the Workflow is running
  (only the urgent variant checks "before first run"). Another landing may then
  start and overlap. Resume waits correctly behind `ActiveWorkLock`, and the
  merge call is fenced by `expected_sha`, so this is wasted work rather than
  corruption — but it is a deliberate trade of strict mutual exclusion for
  freedom from starvation (`15bcc37187`). Lean can state both; you have to pick.
- **Q2. Closing a Job leaves its Workflows running.** External close paths
  (`PullRequestMergeCloser`, `PollPullRequestJob#close_with`, …) cancel only
  active Runs; queued/between-steps Workflows survive until
  `closed_job_active_runtime_work` cancels them (production: a running rebase
  with a queued `force_push` on a Job closed as `pr_merged`). Not fixed: some
  Jobs close while a Workflow is still finishing (deploy anchor; possibly merge
  train members closed by the merge poller while the train lands the rest), so a
  central "close cancels all" hook could cancel a train mid-landing — and the
  reconciler's critical auto-repair may already have that race. Also: the
  closers hold the Job lock, cancelling inside it would invert Workflow→Job lock
  order (production logged a deadlock on this repair). Needs your call on which
  Workflows a close should end.
- **Q3. Admin WorkUnits list 500s past page 29** (`Mysql2: Out of sort memory`)
  — found while paging it read-only for O1; not engine-related.

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
