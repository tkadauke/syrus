# Work Engine Simulation Scenarios

These YAML files seed deterministic database states for
`WorkEngine::Simulation::ScenarioRunner`. The simulator then drives the real
reconciler, retry enqueuer, WorkIntent/WorkUnit scheduling, and step dispatcher
while faking only the execution boundary.

Run one scenario:

```sh
bin/simulator spec/fixtures/work_engine_simulations/single_initial_success.yml
```

Run the regression set:

```sh
bin/simulator
```

`bin/simulator` runs every YAML scenario in this directory in series and exits
non-zero when any scenario ends in an unexpected status, which makes it usable
as a grader. By default, `success` and declared-valid `waiting` outcomes pass.
Use `expected_status: stuck` only for diagnostic fixtures that deliberately
verify a stuck condition is detected.

Use these fixtures for incidents that can be represented as persisted state:
Jobs, Epics, WorkIntents, WorkUnits, Workflows, Steps, Runs, locks, and run
diagnostics. For production bugs, copy the smallest relevant shape into a new
YAML file, verify it reproduces the stuck state, fix the bug, then keep the
scenario as a regression.

Most scenarios ignore `workspace_missing` by default because synthetic runs do
not need real workflow directories. To make missing workspaces part of the
scenario, opt into all reconciler diagnostics:

```yaml
reconciler:
  ignored_issue_kinds: []
```

Scenarios that intentionally stop at a valid non-terminal boundary should
declare `wait_states`. This is how the suite represents production states such
as "the first job in an epic is implemented and waiting for operator approval"
or "a downstream epic is waiting for an upstream epic to land." Waiting is not
treated as stuck, but it is opt-in so accidental quiescence still fails the
scenario:

```yaml
success_states:
  first:
    - approved
wait_states:
  first:
    - implemented
```

Scenarios can also include condition-driven external events. Prefer these over
tick numbers so adding or removing workflow steps does not make the fixture
brittle. Useful events include an operator approving implemented Jobs, marking
an upstream Epic complete, GitHub checks changing state, main moving forward,
or a Job being closed externally:

```yaml
events:
  - name: approve once ready
    once: true
    when:
      job:
        id: feature
        state: implemented
    do:
      approve: feature
```

Provider usage can be exhausted and refreshed mid-scenario to reproduce a
quota-outage pause and its automatic resume. `exhaust_provider_usage` records
exhausted usage evidence so the real availability gate, circuit breaker, and
reconciler react; `refresh_provider_usage` records available evidence; and
`wake_provider_admission` runs the real admission wakeup plus the deferred
phase resume the enqueued `WorkflowPhaseAdmissionJob` would run (there are no
queue workers in a simulation). All three take a provider name or
`{ provider: }` hash and default to `codex`:

```yaml
events:
  - name: exhaust codex usage once workflows are running
    once: true
    when:
      any:
        - workflow: { job: first, state: running }
    do:
      exhaust_provider_usage: codex
```

Other external events: `merge_pr` runs the real closed-PR resolution with
the merged flag as the injected fact (`{ job:, merged: }`, default true);
`report_pr_feedback` ingests a fabricated review comment through the real
ingester and dispatches the `pr_comment` workflow when it qualifies
(`{ job:, body:, handle: }`); `report_ci_failure` dispatches the real
`CiFailure` workflow after establishing the safety preconditions the poller
verifies (`{ job:, failed_checks:, base_sha:, base_healthy: }`; pass
`base_healthy: false` to exercise the suppression instead);
`set_job_provider` switches a job's provider through the real setting change
(`{ job:, provider: }`); `break_main_branch` / `heal_main_branch` flip the
repo health columns the main-health gate reads. Failure outcomes can carry
a `failure_code` (`- status: failure` plus `failure_code:`), stamped like a
real step handler would stamp it so `Try` branches match. Workflow event
conditions accept `start_blocked:` alongside `state:` to match on the
current start-block reason.

For end-to-end orchestration scenarios, use `expect:` to describe the final
world state. This lets a scenario model "the operator approves once ready, then
the landing queue drains" without treating the intermediate approval wait as
the desired endpoint. `expect:` also accepts `events`, a list of required
substrings over the tick event log -- use it to pin that the middle of the
story happened, not just the final state. Without this, a pause-then-resume
scenario whose pause silently stops engaging still passes on the final state
alone:

```yaml
expect:
  jobs:
    feature:
      - closed
  queues:
    active_runs: empty
    active_work_units: empty
    landing: empty
```

Event conditions currently support `job`, `workflow`, `work_unit`, and `queue`,
plus `all`, `any`, and `not` composition. Job references can use YAML fixture
keys; the loader translates them to database IDs after seeding.
