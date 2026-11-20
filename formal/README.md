# Formal models (Lean 4)

An experiment in proving properties of the workflow engine and reconciler.
It is **fully independent of Syrus**: nothing here is loaded by Rails, run by a
grader, or required by CI. Breaking it blocks nothing.

## Running

```sh
brew install elan-init     # once; installs the toolchain pinned in lean-toolchain
cd formal
lake build                 # checks every proof and every counterexample
```

A green build means every theorem is proved and every `example ... := by decide`
counterexample was evaluated and holds. There are no `sorry`s; the headline
theorems depend only on Lean's standard axioms (`#print axioms`).

## What is modelled

The ownership layer: `WorkIntent`, `WorkUnit`, `WorkUnitLock`,
`WorkIntents::TerminalUnitSync`, and the reconciler's classifiers and repairs for
those records (`classify_*work_unit*` / `classify_*work_intent*` and their
`RepairExecutor::Policies`). Each Lean definition mirrors one Ruby method as
written, including the guards it does *not* have. The modelling simplifications
are listed at the top of `SyrusModel/WorkUnits.lean`.

| File | Contents |
|---|---|
| `SyrusModel/WorkUnits.lean` | States, world, lifecycle operations, invariants |
| `SyrusModel/Reconciler.lean` | Classifiers and repairs |
| `SyrusModel/Proofs.lean` | Invariant preservation, repair soundness and idempotence |
| `SyrusModel/LockSafety.lean` | Lock mutual exclusion for running units |
| `SyrusModel/Counterexamples.lean` | Concrete worlds where a property fails |

## Results so far

Proved, for worlds of any size:

- Every lifecycle operation (`block!`, `unblock!`, `mark_running!`,
  `mark_terminal!`, `preempt!`) and every modelled repair preserves:
  only active units hold locks, and an active unit's intent is open.
- `preempt!` never rewrites a `succeeded`/`failed` outcome.
- Repairs clear the issue they target and are idempotent.
- `classify_terminal_work_units_with_active_locks` cannot fire on a state the
  lifecycle methods produce; it only catches corruption from elsewhere.
- **Lock safety:** if each Workflow has at most one WorkUnit, any sequence of
  lifecycle steps keeps every running, conflict-enforcing unit holding its own
  locks, so two such units never need the same key at once.

Counterexamples (leads to check against the Ruby, not automatically bugs):

1. Finished units are re-entrant: the lifecycle methods have no state guard.
   This is by design, since retries reuse the unit.
2. The one-unit-per-Workflow assumption is load-bearing. With two units on one
   Workflow, the "same runtime owner" skip in `ensure_active_locks!` lets a key
   escape to an unrelated unit while the first is still running. The schema
   does not enforce uniqueness on `work_units.workflow_id`.
3. An intent with one succeeded and one failed unit is satisfied or failed
   depending on repair order. Ruby's classifier order makes success win
   regardless of which attempt is newer.
4. After `cancel_active_work_unit_without_workflow`, the intent stays
   `requested` with no active unit, and an unscoped reconcile considers the
   world clean. The classifiers that relaunch such an intent only run when the
   reconcile is scoped to a `work_intent_id`, and no production caller passes
   one.

## Next steps

- Model unit creation (`Launcher#instantiate`) so retries and new attempts are
  part of the reachable state space, not just operations on existing units.
- Workflow / Step / Run state machines and the terminal-descendant repairs.
- Conformance: export model traces and replay them through
  `spec/fixtures/work_engine_simulations` so the model cannot silently drift
  from the Ruby.
