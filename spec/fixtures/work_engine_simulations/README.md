# Work Engine Simulation Scenarios

These YAML files seed deterministic database states for
`WorkEngine::Simulation::ScenarioRunner`. The simulator then drives the real
reconciler, retry enqueuer, WorkIntent/WorkUnit scheduling, and step dispatcher
while faking only the execution boundary.

Run one scenario:

```sh
RAILS_ENV=test bin/rails 'syrus:work_engine:simulate[spec/fixtures/work_engine_simulations/single_initial_success.yml]'
```

Run the regression set:

```sh
bin/rspec spec/services/work_engine/simulation/scenario_runner_spec.rb
```

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
