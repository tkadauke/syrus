# State machines

Use these rules for AASM transitions and lifecycle propagation across Jobs, Workflows, Steps, and Runs.

- **AASM events on Run, Step, and Workflow** — lifecycle callbacks set
  timestamps after AASM persists the transition. Ordinarily call `start!`,
  `succeed!`, `fail!`, or `cancel!`, then `save!` to persist those callback
  changes. Inside an outer transaction, do not follow a bang event with a
  redundant save: Rails commit callbacks would see only that last save and
  miss the state transition. Set the timestamp before the bang event instead,
  so the transition persists both changes and remains visible to
  `after_update_commit` guards.
- **A failed Workflow must leave a failed Job.** `Job#mark_failed` only
  transitions `from: :running`, so a Workflow whose first Run fails *before the
  Workflow starts* (`started_at` nil, Job never left `:queued`) hit
  `return unless job.may_mark_failed?` and silently propagated nothing —
  leaving Workflow `failed` / Job `queued`. That pair is invisible to the
  operator: the "Just failed" folder is `scope.where(state: "failed")` on the
  **Job**, so it reads healthy while nothing works on it and anything stacked
  behind it stays blocked (the queued-workflow lifecycle regression, fifteen hours, three Jobs waiting).
  `Workflows::JobLifecyclePropagation#fail!` now starts a queued Job whose
  Workflow never started before failing it, and `ReconcileJobStatesJob::Plan`
  carries the `["queued", "failed"]` pair — the one drift pair from `queued`
  that was missing — as the safety net.
- **AASM event guards: ALWAYS `may_X?` before `state_X!`.** The Job
  (and Workflow, and Step) AASM machines run with
  `whiny_transitions: false` — `job.approve!` on a non-approvable Job
  silently no-ops. That made the auto-approval bug (`7fb6aae`)
  invisible until a Job got stuck. Pattern:
  ```ruby
  job.approve!(via: "operator", by_user: user) if job.may_approve?
  ```
  When you need the transition to be definite (not "skip silently if
  not legal"), wrap it in a service that re-checks state and dispatches
  side effects — `LandingQueueProcessor.try_land!` is the canonical
  example. The State machine surface for Job is documented in
  `docs/job-state-audit.md`.
