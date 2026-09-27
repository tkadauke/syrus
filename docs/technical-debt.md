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

## Job God Object

- **Introduced for:** historical core workflow ownership.
- **Owner area:** Job model / workflow orchestration
- **Code:** `Job` (`app/models/job.rb`) plus same-class concerns under
  `app/models/concerns/job_*`.
- **Why it exists:** `Job` still owns issue identity, PR identity, branch
  naming, lifecycle state, approvals, landing queue snapshots, dependency
  resolution, prompt provenance, skill routing, and UI-facing status behavior.
  Extracting same-class concerns makes the file easier to scan, but it does not
  reduce the coupling: callbacks and associations still make `Job` the place
  every workflow concept has to touch.
- **Removal condition:** lifecycle, GitHub identity, approval policy,
  dependency graph, and landing queue state each have explicit owner objects
  with narrow public APIs, and `Job` is reduced to persisted identity plus
  simple associations.
- **Removal work:** move behavior into purpose-built services/models with
  regression specs around Job lifecycle, dependency satisfaction, and landing
  queue admission; delete same-class concerns once their responsibilities have
  real owners.

## WorkEngine Reconciler Monolith

- **Introduced for:** WorkUnit repair and runtime consistency work.
- **Owner area:** WorkEngine reconciliation / repair planning
- **Code:** `WorkEngine::Reconciler`
  (`app/services/work_engine/reconciler.rb`),
  `WorkEngine::RepairPlanner`, and `WorkEngine::RepairExecutor`.
- **Why it exists:** reconciliation, diagnosis, planning, repair execution,
  event writing, and operator-facing explanation all live in a small number of
  very large classes. That keeps repair logic centralized, but it makes new
  repair paths risky because a local change can alter planning, execution, and
  reporting at the same time.
- **Removal condition:** each repair family has a focused planner/executor pair
  behind a shared interface, the reconciler only coordinates scanning and
  dispatch, and activity events remain equivalent for existing operator views.
- **Removal work:** extract one repair family at a time into named repair
  objects, add planner/executor contract specs, and retire the central
  conditional branches after the last extracted repair path owns its behavior.

## Desktop And Web View-Model Duplication

- **Introduced for:** desktop app distribution.
- **Owner area:** desktop / app frontend API contracts
- **Code:** `desktop/src/**`, `app/frontend/**`, and the JSON payloads they
  independently consume.
- **Why it exists:** the desktop app is a second hand-maintained React frontend
  for many of the same inbox and status workflows the web app renders. Without
  a shared API contract or shared view-model package, feature work can ship in
  one surface while silently drifting in the other.
- **Removal condition:** desktop and web consume generated or shared typed
  view-model contracts for shared workflows, and CI verifies both surfaces
  against the same payload fixtures or schema.
- **Removal work:** identify the shared inbox/status payloads, introduce a
  contract generation or fixture-validation path, migrate both frontends to it,
  and remove duplicate hand-written shape definitions.

## MySQL-Incompatible Ruby Schema Dump

- **Introduced for:** SQLite-first development and hand-edited schema drift.
- **Owner area:** database schema hygiene
- **Code:** `db/schema.rb` and JSON-column migrations.
- **Why it exists:** the Ruby schema dump is produced from SQLite in normal
  development, but MySQL rejects database defaults on JSON columns. When JSON
  defaults appear in the dump, `db:schema:load` can fail even though the real
  migrations use the model-default pattern.
- **Removal condition:** `db/schema.rb` contains no JSON column defaults,
  migrations remain the source of truth for JSON-column defaults, and
  `db:schema:load` against MySQL succeeds from a clean checkout.
- **Removal work:** keep the schema dump free of JSON defaults, enforce that
  with the MySQL fresh-install compatibility spec, and add a real idempotent
  migration whenever a persisted default-like invariant is needed.

## MySQL Partial-Index Fiction

- **Introduced for:** pending dependency and preview-environment uniqueness /
  lookup constraints.
- **Owner area:** database portability
- **Code:** partial `where:` indexes in `db/schema.rb` and the migrations that
  add unresolved dependency and active preview indexes.
- **Why it exists:** SQLite and PostgreSQL-style partial indexes express the
  desired constraints clearly, but MySQL does not enforce those predicates as
  partial indexes. The dumped schema can therefore describe stricter behavior
  than production actually has.
- **Removal condition:** every partial-index use has a MySQL-native equivalent
  such as generated columns, explicit active-owner keys, or application-level
  constraints with database-backed tests for the MySQL behavior.
- **Removal work:** inventory the `where:` indexes, replace each production
  constraint with a MySQL-enforced design, and remove any schema predicates that
  are documentation-only on MySQL.

## Dual Runtime Lifecycle Layers

- **Introduced for:** WorkUnit rollout alongside the existing AASM pipeline.
- **Owner area:** workflow runtime architecture
- **Code:** AASM-backed `Job` / `Workflow` / `Step` / `Run` state transitions
  plus `WorkIntent` / `WorkUnit` / `WorkDefinition` scheduling ownership.
- **Why it exists:** WorkUnits add explicit ownership, locks, and repair
  policy without replacing the legacy state machines yet. During the migration,
  lifecycle transitions, repair decisions, and UI projections are implemented
  in both layers, which doubles the surface area for inconsistencies.
- **Removal condition:** all runtime starts, retries, pauses, resumes,
  auto-merge, merge-train, and repair paths are driven by WorkIntent/WorkUnit
  ownership, and the AASM models only mirror state needed for display or are
  retired entirely.
- **Removal work:** finish migrating path ownership into WorkDefinitions,
  collapse presentation fallbacks, delete duplicated transition code, and keep
  compatibility shims only where persisted historical rows require them.

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
