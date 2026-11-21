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

CI runs the same build on every change to `formal/`
(`.github/workflows/formal-ci.yml`). How the models will stay in sync with the
Ruby and plug into Syrus is planned in [INTEGRATION.md](INTEGRATION.md).

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

## DOC-44 Phase 1 kernel (`SyrusModel/Kernel/`)

The focused models above were each built around one finding, over a fixed
`Fin n` universe. The kernel is the shared core DOC-44 Phase 1 asks for:
WorkIntent → WorkUnit → Workflow → Step → Run plus locks, as id-keyed lists,
so the same definitions run in the executable oracle on JSON input and are
reasoned about in proofs.

- `Kernel/Basic.lean`: states, the world, and `Valid` (unique ids, referential
  integrity, one active holder per lock key).
- `Kernel/Reconcile.lean`: the terminal-cleanup family (`diagnose`,
  `reconcile`) with `reconcile_idem` (reconciling twice is reconciling once)
  and `diagnose_reconcile` (no own issue survives), over arbitrary worlds.
- `Kernel/Examples.lean`: small worlds checked by `decide`; the first oracle
  and conformance fixtures.

- `Kernel/Preservation.lean`: `reconcile_valid` (a valid world stays valid) and
  repair scoping (a record changes only under its own finished Workflow).

- `Kernel/Dependencies.lean`: the four satisfaction modes, with `never_both`
  (never satisfied and terminally failed at once) and `closed_decided` (a closed
  upstream Job always decides its dependency); found F48.

- `Kernel/Json.lean`: the canonical JSON schema (schema version 1) and
  `validB`, the executable validity check, with `validB_sound` (it never calls
  an invalid world valid).
- `Oracle.lean`: the `syrus_oracle` executable. It reads one world as JSON on
  stdin and prints validity, issues, the reconciled next state, and the issues
  left in it (always none, by `diagnose_reconcile`, and printed so consumers
  can check). Malformed input exits 2 with an `error` object.

```
lake build syrus_oracle
.lake/build/bin/syrus_oracle < contracts/work_engine_traces/lost_cleanup.json
```

`contracts/work_engine_traces/` holds the first canonical fixtures (DOC-44,
"Shared contract corpora").

Phase 1 is complete in this scope.

## DOC-44 Phase 2: Ruby simulator conformance

- `WorkEngine::CanonicalWorld` (Ruby) exports a database world in this schema.
  Its spec mirrors `Valid`, so an export the oracle would reject is caught
  without Lean.
- `spec/services/work_engine/lean_oracle_conformance_spec.rb` loads every
  simulation scenario in `spec/fixtures/work_engine_simulations/`, exports it,
  and runs both the Ruby reconciler and `syrus_oracle`. It projects both
  diagnoses onto the targets the kernel models and requires them to agree. It
  runs only where the oracle is built, so the regular suite does not need Lean.

The first pass agreed on 96 of 99 scenarios. Two differences came from the
projection: Ruby releases a unit's locks inside its outcome repair, so it does
not report them separately. The third was a kernel bug. The kernel cancelled a
failed Workflow's queued tail, which retry-from-failed-step continues through
(decision NY4). `World.stepStale` now encodes that, and every proof still
holds. All 99 scenarios agree now; the case is a fixture
(`failed_with_queued_tail.json`, `Examples.failedWithQueuedTail`).

Next in Phase 2: compare at every simulation tick, not only the starting world,
and generate and shrink differential traces.

## Next steps

- Model unit creation (`Launcher#instantiate`) so retries and new attempts are
  part of the reachable state space, not just operations on existing units.
- Workflow / Step / Run state machines and the terminal-descendant repairs.
- Conformance: export model traces and replay them through
  `spec/fixtures/work_engine_simulations` so the model cannot silently drift
  from the Ruby.
