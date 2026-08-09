# Epic Reconciliation

Epic reconciliation reviews combined Epic changes for inter-Job consistency, shared-surface regressions, naming conflicts, migration issues, and cross-cutting concerns that individual child-Job review may not catch.

Epics reconcile inside merge-train landing, after Syrus has built the integration branch and before prepare, graders, coverage, and landing. Syrus no longer creates standalone `Reconciliation: ...` child Jobs.

## How it works

When merge trains are enabled and every open Epic child Job is approved, Syrus dispatches a `merge_train` workflow. The train:

1. **Builds one integration branch** — child PR branches are rebased into the train in dependency order.
2. **Runs `merge_train_reconcile`** — the agent inspects the integrated tree for sibling inconsistencies and may make focused fixes on the integration branch.
3. **Continues through normal gates** — no-diff reconciliation is successful; any reconciliation edits are committed and then validated by prepare, graders, coverage, mergeability, and landing.

Operator and chat guidance should talk about the merge-train reconciliation phase. If reconciliation is blocked or failed, retry or inspect the `merge_train` workflow and its `merge_train_reconcile` step. Do not propose a new standalone reconciliation Job.

## Landing gate

For current Epics with merge trains enabled, child Jobs do not land through the per-Job auto-merge path. They stay approved with `blocked_reason: "waiting for Epic merge-train"` until all open siblings are approved, then land atomically through the train.
