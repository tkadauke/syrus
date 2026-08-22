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
