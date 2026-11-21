# Integrating the formal models with Syrus

How the Lean models in this directory should stay true as the Ruby changes,
and how they plug into the rest of Syrus. Agreed direction; only the CI gate is
built so far. Everything else waits until we decide how Lean runs inside Syrus
itself (most likely the repository devcontainer).

## The problems

1. **Nothing runs the models automatically.** `lake build` only happens when
   someone remembers to run it.
2. **Models drift silently.** Each Lean file is a hand-written mirror of
   specific Ruby methods. Change the Ruby and nothing says the proof is now
   about code that no longer exists.
3. **The inventory goes stale.** A new reconciler classifier, or a fix to an
   existing one, does not touch `coverage/coverage.json`.
4. **Syrus's own agents cannot run Lean.** Most engine changes are made by
   Syrus Jobs, and the workers have no Lean toolchain.

## The layers

| # | Layer | What it does | Status |
|---|---|---|---|
| 1 | **CI gate** | `.github/workflows/formal-ci.yml` installs the pinned toolchain, runs `lake build`, and fails on `sorry`/`admit`. Runs on changes to `formal/**`. | **Built.** Required-check status is a branch-protection setting. |
| 2 | **Drift detection** | `formal/mirrors.yml` maps each model to the Ruby methods it mirrors, with a hash of each method's source. An architecture spec recomputes the hashes and fails with "`<Model>.lean` may be stale" when mirrored code changes, so the model is reviewed in the same PR. The CI gate then also triggers on the mirrored files. | Waiting on the Lean-in-Syrus decision |
| 3 | **Conformance fixtures** | For the pure decision functions (ready set, Epic turn, merge-train evidence, orphaned-queue classification, review barrier, auto-approval), a small Lean program enumerates small inputs and writes the model's answers to JSON fixtures; a Ruby spec runs the real method on the same inputs and compares. Closes the "is the model actually the code?" gap Lean alone cannot. Stateful properties (closure, locks) go through simulator scenarios instead. | Waiting |
| 4 | **Proofs as production alarms** | States proved unreachable keep their reconciler repair but get `expected: never` in `coverage.json`. A daily check (Syrus scheduled task or report over the read-only admin API) compares reconciler activity with those expectations: a "proved impossible" state in production means an assumption is wrong or a model has drifted. Also measures the effect of fixes after deploy. | Waiting |
| 5 | **Inventory completeness** | An architecture spec, in the style of `repair_plan_completeness_spec.rb`, requires every issue kind the reconciler can emit to have an entry in `coverage.json`, so adding a repair forces the question "can we prevent this instead?". The coverage page is regenerated in CI. | Waiting |
| 6 | **Documentation home** | A pointer in `CLAUDE.md` (progressive disclosure) and a short page under `docs/engineering/architecture/` on what is modelled and how to update it. `formal/README.md` stays the how-to; `FINDINGS.md` stays free of instance identifiers. | Waiting |
| 7 | **Lean inside Syrus** | Syrus Jobs run `lake build` as a grader (via the repository devcontainer once container execution is ready), so agents get model feedback before CI. Then the CI gate can become required everywhere. | The decision everything above waits on |

## Agreed so far

- The CI gate exists now (layer 1).
- Layers 2–6 wait until layer 7 is decided.

## Open

- How Lean runs inside Syrus (layer 7; devcontainer most likely).
- When mirrored code changes: does the changing agent update the model
  (prompted by the drift spec and the implement instructions), or is it
  flagged for operator review?
- When the CI gate becomes a required check.
