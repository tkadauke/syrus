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

> **Operator decision (2026-11-22, lean-plan site):** go ahead with all seven layers.

## The layers

| # | Layer | What it does | Status |
|---|---|---|---|
| 1 | **CI gate** | `.github/workflows/formal-ci.yml` installs the pinned toolchain, runs `lake build`, and fails on `sorry`/`admit`. Runs on changes to `formal/**`. | **Built.** Required-check status is a branch-protection setting. |
| 2 | **Drift detection** | `formal/mirrors.yml` maps each model to the Ruby methods it mirrors, with a hash of each method's source. An architecture spec recomputes the hashes and fails with "`<Model>.lean` may be stale" when mirrored code changes, so the model is reviewed in the same PR. | **Built** (11 models, 19 methods; Ruby only). The CI gate is *not* extended to the mirrored files: the Lean build reads no Ruby, so a Ruby change cannot change its result, and the drift spec already runs in the main CI on every change. |
| 3 | **Conformance fixtures** | For the pure decision functions (ready set, Epic turn, merge-train evidence, orphaned-queue classification, review barrier, auto-approval), a small Lean program enumerates small inputs and writes the model's answers to JSON fixtures; a Ruby spec runs the real method on the same inputs and compares. Closes the "is the model actually the code?" gap Lean alone cannot. Stateful properties (closure, locks) go through simulator scenarios instead. | **Built.** `formal/Fixtures.lean` (`lake exe syrus_fixtures`) writes `formal/fixtures/<name>.json`; `spec/formal/` compares the Ruby with them; formal CI regenerates every fixture and fails if a committed one differs. Done: auto-approval (8 cases), merge-train evidence (48 cases; found the model had drifted, F115) the Epic turn (48 cases; the Ruby's dependency-aware turn skip is not modelled) orphaned-queue classification (32 cases) the review barrier (32 cases, after extending the model to the code's three ways of passing, F116) and the distributed ready set (2,048 cases: every three-Step Workflow from every cursor). Two of the six found a stale model. |
| 4 | **Proofs as production alarms** | States proved unreachable keep their reconciler repair but get `expected: never` in `coverage.json`. A daily check (Syrus scheduled task or report over the read-only admin API) compares reconciler activity with those expectations: a "proved impossible" state in production means an assumption is wrong or a model has drifted. Also measures the effect of fixes after deploy. | **Built, not scheduled.** Six items are marked `expected: never`; `Formal::ProvedUnreachableAlarm` and `bin/rails formal:alarms` (`HOURS=24`, exits 1 on a sighting) compare them with `work_engine_reconciler_activity_events`. First reading (2026-11-23): one kind seen, `terminal_work_unit_active_children`, 21 times, all before its fix (F29) reached main; none since. Running it daily is an operator choice (a scheduled task on the instance). |
| 5 | **Inventory completeness** | An architecture spec, in the style of `repair_plan_completeness_spec.rb`, requires every issue kind the reconciler can emit to have an entry in `coverage.json`, so adding a repair forces the question "can we prevent this instead?". The coverage page is regenerated in CI. | **Built** (`spec/architecture/formal_coverage_completeness_spec.rb`): both directions, with a Prism scan that follows ternaries, kind helpers and `issue(**helper)` splats; it found one kind with no entry. The page is not yet regenerated in CI. |
| 6 | **Documentation home** | A pointer in `CLAUDE.md` (progressive disclosure) and a short page under `docs/engineering/architecture/` on what is modelled and how to update it. `formal/README.md` stays the how-to; `FINDINGS.md` stays free of instance identifiers. | **Built** (`docs/engineering/architecture/formal-models.md`, listed in the architecture index and `CLAUDE.md`). |
| 7 | **Lean inside Syrus** | Syrus Jobs run `lake build` as a grader (via the repository devcontainer once container execution is ready), so agents get model feedback before CI. Then the CI gate can become required everywhere. | The decision everything above waits on |

## Agreed so far

- The CI gate exists now (layer 1).
- Drift detection exists now (layer 2): `formal/mirrors.yml`,
  `bin/formal-mirrors`, `spec/architecture/formal_mirrors_spec.rb`.
- Inventory completeness exists now (layer 5).
- The documentation home exists now (layer 6).
- Production alarms exist now (layer 4); scheduling them is open.
- Conformance fixtures exist now (layer 3) for all six decision functions:
  `formal/Fixtures.lean`, `formal/fixtures/`, `spec/formal/`, and a check in
  formal CI.
- The operator approved all seven layers (2026-11-22); layers 3–6 do not depend
  on layer 7 and are built in order.

## Open

- How Lean runs inside Syrus (layer 7; devcontainer most likely).
- When mirrored code changes: does the changing agent update the model
  (prompted by the drift spec and the implement instructions), or is it
  flagged for operator review? Until decided, the failing drift spec asks
  whoever made the change, agent or person, to review the model and update it.
- When the CI gate becomes a required check.
- Whether to run `bin/rails formal:alarms` daily on the instance (layer 4).
