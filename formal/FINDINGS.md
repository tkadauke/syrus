# Findings ledger

One entry per finding from the Lean bug hunt. Verdicts:

- **fixed** — reproduced by a failing Ruby spec, fixed, spec green, Lean model updated.
- **by design** — the counterexample describes intended behavior; the model now says so.
- **open** — reproduced or suspected, waiting for a decision.
- **model** — the model was wrong; nothing in Ruby changed.

Evidence notes record where the claim came from (model, code reading,
production telemetry via the read-only admin API).

---

## F1. Reconciler and JobWakeup fight over dependency waits — fixed

**Property.** The reconciler never "repairs" a state the domain logic
deliberately produces (`Agreement.Agrees`), so the two controllers converge.

**Counterexample.** `Agreement.before_oscillates`: an intent `waiting` on an
unsatisfied dependency, with an active WorkUnit. `classify_waiting_work_intents_with_active_units`
calls `request!`; the next `JobWakeup` → `Scheduler.evaluate!` parks it
`waiting` again. Forever.

**Evidence.** Production, ~9 hours of `repair_executed` events: 2,801 applied
`clear_waiting_work_intent_active_unit` repairs — 70% of all repairs. The same
ten intents were each re-detected ~100 times over 90 minutes, every one with
`wait_reason: dependency`. The Job page shows the intent's wait reason, so it
flickered on and off.

**Which side was wrong.** The reconciler. `JobWakeup` parking the intent while
the Launcher's unit exists is asserted by `job_wakeup_spec.rb`;
`WorkUnit#reactivate_work_intent!` treats `waiting` as compatible with an active
unit; the Job page serializer renders it. Only a *stale* wait (gates now pass)
is abnormal.

**Fix.** The classifier and the executor policy skip waits whose intent gates
still fail.

**Proofs.** `after_agrees`, `after_commutes`, `after_converges` (any interleaving
of wakeups and reconciles is stable after one wakeup), `after_clears_stale`,
`after_keeps_justified`.

**Spec.** `reconciler_spec.rb` — "leaves a justified dependency wait alone when
the intent already has an active WorkUnit" (red before, green after).

**Review note.** Expect `waiting_work_intent_with_active_unit` to all but vanish
from reconciler activity after deploy.

---

## Carried over from the first model round

- **O1. One WorkUnit per Workflow is assumed, not enforced** — open.
  `LockSafety.steps_lock_safe` needs it; `Examples.shared` shows lock escape
  without it. No unique index on `work_units.workflow_id`.
- **O2. Intent-scoped relaunch classifiers are unreachable in production** —
  open. No caller passes `work_intent:` to `Reconciler.request`.
- **O3. Mixed succeeded/failed units: success wins regardless of recency** —
  open, low.
- **D1. Finished WorkUnits are re-entrant** — by design (retries reuse the unit).
