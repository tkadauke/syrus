# Technical Debt Register

This file tracks intentional, known debt that should not silently become
permanent architecture. Entries should be concrete enough that a future agent can
tell when the debt is still necessary and when it can be removed.

## Work Units Legacy Scheduler And Reconciler Fallbacks

- **Introduced for:** `docs/plans/work-units-and-execution-resilience.md`
- **Owner area:** WorkIntent / WorkUnit migration
- **Code:** remaining workflow-first UI/controller diagnostics, start-block
  artifact projections kept for audit/display compatibility, and
  migration-only adapters that preserve pre-WorkUnit data. Production workflow
  launch paths are guarded by `spec/architecture/workflow_launch_funnel_spec.rb`
  and should continue to enter through `WorkUnits::Launcher`.
- **Why it exists:** WorkUnits are replacing brittle runtime inference
  incrementally. The cleanup passes removed replay/start-block artifact
  ownership fallbacks from scheduling, wakeups, filters, active runtime checks,
  and Epic-wide conflict/queue lookups; remaining debt is in workflow-first
  presentation/diagnostics and compatibility projections that still need to
  become WorkIntent/WorkUnit native or be deleted after production soak.
- **Removal condition:** WorkUnit-backed scheduling, wakeups, repair execution,
  and UI projections have been tested in production and have stayed stable for a
  full operational window, with no active production path requiring direct
  Workflow ownership inference. The one-time active-Workflow migration has run
  on known installations, and no runtime bridge/backfill job exists.
- **Removal work:** Delete the old brittle fallback implementation path by path:
  remove workflow-first diagnostic projections, delete migration-only
  compatibility specs, and keep only tests that prove all runtime work enters
  through WorkIntent/WorkUnit ownership.
