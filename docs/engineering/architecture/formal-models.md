# Formal models

`formal/` holds Lean 4 models of the workflow engine, the reconciler and a
growing set of decision functions around them. Each model mirrors specific Ruby
methods as written, including the guards they do not have, and its theorems
either prove a property of that code or exhibit a concrete state where the
property fails. This page says what is modelled and what keeps the models true
as the Ruby changes. How to build and extend them is in
[formal/README.md](../../../formal/README.md); the integration plan is
[formal/INTEGRATION.md](../../../formal/INTEGRATION.md).

## What is modelled

- **The ownership layer:** `WorkIntent`, `WorkUnit`, `WorkUnitLock`, their
  lifecycle operations, and the reconciler's classifiers and repairs for them
  (`formal/SyrusModel/WorkUnits.lean`, `Reconciler.lean`, `Proofs.lean`,
  `LockSafety.lean`).
- **The reconciler kernel** (`formal/SyrusModel/Kernel/`), which the Lean oracle
  compares with the Ruby reconciler on every simulation scenario
  (`spec/services/work_engine/lean_oracle_conformance_spec.rb`).
- **One file per property** for most of `formal/SyrusModel/`: a decision
  function or a protocol (the ready set, the Epic turn, review barriers,
  merge-train evidence, row-lock order, landing slots, stacked-Job conflict
  recovery, plugin trust, backup retention, and more). Each file's header says
  which Ruby it mirrors and what it proves.
- **The coverage inventory**, `formal/coverage/coverage.json`: every reconciler
  issue kind and engine property, with whether it is proved, partly proved, or
  by design.

## What keeps the models true

| Check | Where | Fails when |
|---|---|---|
| The proofs build | `.github/workflows/formal-ci.yml` (`lake build`, no `sorry`) | a proof or counterexample no longer holds |
| Drift detection | `spec/architecture/formal_mirrors_spec.rb`, `formal/mirrors.yml` | a Ruby method a model mirrors changed |
| Conformance fixtures | `spec/formal/`, `formal/fixtures/`, formal CI | the Ruby and the model answer differently on the same input, or a committed fixture is stale |
| Inventory completeness | `spec/architecture/formal_coverage_completeness_spec.rb` | the reconciler emits an issue kind the inventory lacks, or the inventory names one it no longer emits |
| Row-lock order | `spec/support/lock_order.rb`, `lib/syrus/lock_order.rb` | a transaction takes row locks out of `Syrus::LockOrder::MODELS` |
| Production alarms | `Formal::ProvedUnreachableAlarm`, `bin/rails formal:alarms` | an issue kind marked `"expected": "never"` in `coverage.json` occurred in production |

## When a check fails

- **A model may be stale** (drift detection): read the changed method beside
  the model the failure names. If the behaviour the model describes changed,
  update the model and its fixture, then run `bin/formal-mirrors --update`.
- **A conformance case disagrees:** either the model is out of date (fix the
  model and regenerate its fixture) or the code changed a decision the model
  relied on (fix the code, or decide the new behaviour is intended and update
  the model). Two of the six fixtures found stale models when they were
  written.
- **An issue kind has no inventory entry:** add an item naming it, and ask
  whether the state can be made unreachable instead of repaired.

Models of Go or TypeScript code (the CLI's checkout hooks, the desktop's
rollback image) are not covered by drift detection, which reads Ruby only.
