# Technical Debt Register

This file tracks intentional, known debt that should not silently become
permanent architecture. Entries should be concrete enough that a future agent can
tell when the debt is still necessary and when it can be removed.

## Work Units Legacy Scheduler And Reconciler Fallbacks

- **Introduced for:** `docs/plans/work-units-and-execution-resilience.md`
- **Owner area:** WorkIntent / WorkUnit migration
- **Code:** `WorkUnits::WorkflowBlockProjection`
  (`app/services/work_units/workflow_block_projection.rb`) — a pure
  presentation projection with 2 call sites (`MainHealthChangedService`,
  `StepDispatcher`) that mirrors a workflow's start-blocked reason onto its
  `WorkUnit` for audit/display. This is the genuinely narrow soak-then-remove
  target in this entry; `WorkUnits::StartBlock` is load-bearing (20+ call
  sites across scheduling, wakeups, filters, and the landing queue) and
  should stay documented as-is, not be folded into this removal.
- **Why it exists:** WorkUnits are replacing brittle runtime inference
  incrementally. The cleanup passes removed replay/start-block artifact
  ownership fallbacks from scheduling, wakeups, filters, active runtime checks,
  and Epic-wide conflict/queue lookups; `WorkflowBlockProjection` remains as a
  workflow-first compatibility projection that still needs to become
  WorkIntent/WorkUnit native or be deleted after production soak.
- **Removal condition:** WorkUnit-backed scheduling, wakeups, repair execution,
  and UI projections have been tested in production and have stayed stable for a
  full operational window, with no active production path requiring direct
  Workflow ownership inference. The one-time active-Workflow migration
  (`BackfillActiveWorkUnits`) has run on known installations.
- **Removal work:** Delete `WorkUnits::WorkflowBlockProjection` and its two
  call sites once `WorkUnit#blocked?`/`blocked_reason` is populated natively
  instead of projected from workflow start-block state; keep only tests that
  prove all runtime work enters through WorkIntent/WorkUnit ownership.

## Job#mark_no_change_needed Legacy Repair Transition

- **Introduced for:** pre-dates the current no-change closure path.
- **Owner area:** Job state machine / `JobStateRepair`
- **Code:** `Job#mark_no_change_needed` (`app/models/job.rb`), reachable only
  through `JobStateRepair::ALLOWED_EVENTS` (manual operator repair tooling).
- **Why it exists:** normal no-change propagation now closes the Job with
  `closure_reason: "no_changes"` directly; this event only exists for
  manually repairing old rows stuck in the `running` state from before that
  path existed. Not urgent to remove, just worth tracking so it isn't
  forgotten.
- **Removal condition:** confirm no `Job` rows can still reach `running` with
  an outcome that needs this manual repair path (i.e. the `no_change_needed`
  state itself is fully legacy), and no operator tooling depends on invoking
  this event.
- **Removal work:** remove `mark_no_change_needed` from `Job` and from
  `JobStateRepair::ALLOWED_EVENTS`, plus its specs.
