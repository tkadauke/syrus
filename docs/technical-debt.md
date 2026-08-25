# Technical Debt Register

This file tracks intentional, known debt that should not silently become
permanent architecture. Entries should be concrete enough that a future agent can
tell when the debt is still necessary and when it can be removed.

## Work Units Legacy Scheduler And Reconciler Fallbacks

- **Introduced for:** `docs/plans/work-units-and-execution-resilience.md`
- **Owner area:** WorkIntent / WorkUnit migration
- **Code:** remaining direct active-Workflow scans, launch paths that bypass
  `WorkUnits::Launcher`, workflow-first UI/controller assumptions, and
  migration adapters that preserve pre-WorkUnit scheduler behavior.
- **Why it exists:** WorkUnits are replacing brittle runtime inference
  incrementally. The first cleanup pass removed replay/start-block artifact
  ownership fallbacks from scheduling, wakeups, filters, and reconciler active
  runtime checks; remaining debt is in launch funnels and workflow-first
  presentation/diagnostics that still need to become WorkIntent/WorkUnit native.
- **Removal condition:** WorkUnit-backed scheduling, wakeups, repair execution,
  and UI projections have been tested in production and have stayed stable for a
  full operational window, with no active production path requiring direct
  Workflow ownership inference.
- **Removal work:** Delete the old brittle fallback implementation path by path:
  remove remaining launch bypasses and workflow-first runtime checks, delete
  migration-only compatibility specs, and keep only tests that prove all runtime
  work enters through WorkIntent/WorkUnit ownership.
