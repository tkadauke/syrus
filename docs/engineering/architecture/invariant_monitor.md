# Invariant monitor

The invariant monitor codifies the operator's periodic failure sweep. Each
invariant is a small check over persisted state that must hold at every
moment; a violation names its subject and carries the evidence needed to act.

## API

`app/services/invariants.rb` is the entry point:

```ruby
report = Invariants.evaluate(now: Time.current)                        # every invariant
report = Invariants.evaluate(now: now, only: %w[retry_storms])        # a subset
report = Invariants.evaluate(now: now, scope: Invariants::Scope.for_jobs(job_ids))
report = Invariants.evaluate(now: now, options: { "retry_storms" => { max_failures: 3 } })

report.ok?           # no violations and no invariant raised
report.violations    # [Invariants::Violation]
report.errors        # results whose invariant raised; the others still ran

Invariants::FailedBlockers.call(now: now, min_age: 30.minutes)         # one check
```

Invariants are pure: they read the database, compare times against the `now:`
they are given, and never write. That is what lets the same objects serve
three callers:

- `InvariantMonitorJob` (recurring, every 15 minutes) evaluates the whole
  instance and hands the report to `Invariants::Recorder`, the only writer. The
  recorder keeps one open `InvariantViolation` row per fingerprint, refreshes
  it while the violation persists, and resolves it the first clean evaluation
  that no longer reports it. An invariant that raised resolves nothing.
- `GET /api/v1/admin/invariants` evaluates live (`?only=`, `?job_id=`,
  `?include_resolved=true`) and annotates each violation with the recorded
  episode's `first_detected_at` and `detection_count`.
- The work-engine simulator asserts them after every tick of every scenario
  (`WorkEngine::Simulation::InvariantAssertions`), with `Scope.for_jobs`
  limiting evaluation to the scenario's Jobs. Duration thresholds are zeroed
  there and replaced by persistence in ticks, since a simulated tick takes no
  wall-clock time; scenarios that model a violating state declare it under
  `invariants: expected:`. The simulator's fuzz mode
  (`bin/simulator --fuzz`) uses the same assertions as its main oracle. See
  `spec/fixtures/work_engine_simulations/README.md`.

Open episodes also raise the admin `invariant_violations` system alert
(severity `warn`, banner only); its dismissal key is the set of open
fingerprints, so a dismissed banner returns when that set changes.

A `Violation` has a `fingerprint` (`invariant:SubjectType:id[:discriminator]`,
bounded to 200 characters), a `severity` (`critical` or `warning`), a
translated `message` built from `message_params`
(`services.invariants.<key>.violation`), structured `details`, `affected_ids`,
and `since`, when the violating condition began.

## Invariants

| Key | Holds when | Defaults |
|---|---|---|
| `landing_progress` | An approved or landing Job has a queued/running Run, an active WorkUnit (directly or through its Epic), a waiting WorkIntent, or a named landing-queue reason (blocker, Jobs ahead, manual pause). | `threshold: 2h` since the last Run, Workflow, or WorkUnit update. |
| `slot_holders` | Rebase-cap units have a queued/running workflow, an unpaused Job, and no pause request; no terminal unit holds an active lock; landing lane locks are not held by units blocked on an operator-cleared reason or by runnable units whose workflow ended. | `grace: 15m` |
| `retry_storms` | No Job fails the same step kind with the same fingerprint (problem code, error class, and error message with numbers, hex ids, and workspace paths masked; the classification only when no error was recorded, since the classifier can label one error differently per run) more than `max_failures` times in `window`. Critical when the classification says retryable. | `max_failures: 5`, `window: 1h` |
| `failed_blockers` | No failed Job is the stack parent or a declared dependency of a Job still waiting (backlog through approved). The violation lists the blocked Jobs and Epics and the last failure's classification and retryable flag. | `min_age: 1h` |
| `zombie_workflows` | No queued/running Workflow is without a queued/running Step and Run while its WorkUnit is not blocked on a reason; no running Job lacks an active Workflow while its latest Workflow ended or stays blocked. | `threshold: 2h`, `blocked_threshold: 3d` |

## Relationship to the reconciler

Several invariants overlap `WorkEngine::Reconciler` detectors on purpose. The
reconciler classifies issues and plans repairs; the monitor only asserts. When
a repair did not happen, or a state no detector recognizes persists, the
invariant keeps reporting it.

## Adding an invariant

Subclass `Invariants::Base`, declare `DEFAULTS`, implement `#violations`
reading only persisted state and comparing against `now`, honour `scope`
(`scope.restrict(relation, :job_id)`), register it in `Invariants.registry`,
and add `services.invariants.<key>.title` / `.violation` in English, German,
and Latin. Specs need a violating fixture and a non-violating one.
