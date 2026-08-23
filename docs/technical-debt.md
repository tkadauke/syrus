# Technical Debt Register

This file tracks intentional, known debt that should not silently become
permanent architecture. Entries should be concrete enough that a future agent can
tell when the debt is still necessary and when it can be removed.

## Work Units Active Workflow Backfill

- **Introduced for:** `docs/plans/work-units-and-execution-resilience.md`
- **Owner area:** WorkIntent / WorkUnit migration
- **Code:** `WorkUnitsBackfillActiveWorkflowsJob`, `WorkUnits::Backfill`,
  `config/recurring.yml`
- **Why it exists:** Existing queued/running `Workflow` rows may not have
  shadow `WorkIntent` / `WorkUnit` rows when the work-unit migration deploys.
  Running this as a bounded recurring job lets production converge without
  making deploy-time migrations scan or lock live workflow tables.
- **Removal condition:** All production workflow creation paths have gone
  through `WorkUnits::Launcher` for longer than the maximum expected active
  workflow lifetime, and `Workflow.left_outer_joins(:work_unit)
  .where(state: %w[queued running], work_units: { id: nil })` has stayed empty
  for a full operational window.
- **Removal work:** Delete the recurring entry, `WorkUnitsBackfillActiveWorkflowsJob`,
  `WorkUnits::Backfill`, and their specs. Keep the launch-funnel architecture
  spec so the invariant remains enforced.

## Work Units Legacy Scheduler And Reconciler Fallbacks

- **Introduced for:** `docs/plans/work-units-and-execution-resilience.md`
- **Owner area:** WorkIntent / WorkUnit migration
- **Code:** legacy `Workflow` artifact reads, direct active-Workflow scans,
  fallback ownership inference in reconciler/repair/wakeup paths, and
  migration adapters that preserve pre-WorkUnit scheduler behavior.
- **Why it exists:** WorkUnits are replacing brittle runtime inference
  incrementally. During rollout, production may still contain active legacy
  Workflows or rollback paths that rely on the old state/artifact shape, so
  migrated services temporarily keep old reads as a safety fallback.
- **Removal condition:** WorkUnit-backed scheduling, wakeups, repair execution,
  and UI projections have been tested in production and have stayed stable for
  a full operational window, with no active production path requiring direct
  legacy Workflow ownership or start-block artifact inference.
- **Removal work:** Delete the old brittle fallback implementation path by path:
  remove legacy active-Workflow scans from ownership/admission/reconciler code,
  remove direct `start_blocked_*` artifact inference once WorkUnit block state
  is authoritative, delete migration-only compatibility specs, and keep only
  tests that prove all runtime work enters through WorkIntent/WorkUnit
  ownership.
