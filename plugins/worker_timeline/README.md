# Worker Timeline

Worker Timeline visualizes overlapping Syrus activity as a multi-lane
timeline: one lane per worker process (hostname+pid), with Job/Workflow
spans over time. It's meant to answer "what was taking a long time" and
"what was this blocked on before it could start" at a glance, across jobs,
epics, and repositories.

## What It Adds

- A "Worker Timeline" sidebar page (`/worker_timeline`) rendering the macro
  (cross-job) lane view: hand-rolled React+SVG bars, `d3-scale`/`d3-zoom` for
  time-axis scaling and pan/zoom, row virtualization, and filters for
  repository, epic, job status, and worker hostname.
- A hover tooltip per span with the Job/Workflow id, title, duration, and —
  when available — why it was blocked before starting.
- A per-workflow drill-down waterfall (`/worker_timeline/workflow?id=<id>`,
  reachable by clicking a macro-view Workflow span): one lane per Step,
  spans within a lane are that Step's Run attempt(s) (so retries are
  visible), and hovering a not-yet-started Step explains what the Step or
  Workflow was waiting on, reusing the same blocked-reason data as the
  macro view.

This plugin only reads existing data (`WorkflowActivityEvent`,
`SpawnedProcess`, `InstanceVersion`, and Workflow/Step/Run timestamps via
`Timeline::MacroQuery`) — enabling it does not change scheduling, grading, or
job behavior.

## When To Enable

Enable this plugin on instances where operators want a cross-job view of
worker activity and bottlenecks. Keep it disabled on instances that don't
need this level of operational visibility.
