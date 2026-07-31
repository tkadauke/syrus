# Epic Reconciliation

Epic reconciliation reviews combined Epic changes for inter-Job consistency, shared-surface regressions, naming conflicts, migration issues, and cross-cutting concerns that individual child-Job review may not catch.

New Epics no longer create standalone `Reconciliation: ...` child Jobs. Reconciliation now runs inside Epic merge-train landing, after Syrus has built the integration branch and before prepare, graders, coverage, and landing.

## How it works

When merge trains are enabled and every open Epic child Job is approved, Syrus dispatches a `merge_train` workflow. The train:

1. **Builds one integration branch** — child PR branches are rebased into the train in dependency order.
2. **Runs `merge_train_reconcile`** — the agent inspects the integrated tree for sibling inconsistencies and may make focused fixes on the integration branch.
3. **Continues through normal gates** — no-diff reconciliation is successful; any reconciliation edits are committed and then validated by prepare, graders, coverage, mergeability, and landing.

This removes the old fan-in dependency shape where Syrus created a separate reconciliation Job with a single arbitrary PR base and made siblings wait on it.

## Historical standalone Jobs

Existing standalone reconciliation Jobs remain historically readable. Syrus does not destructively remove them, and the legacy compatibility paths still apply:

- `Epic#work_jobs` excludes the linked reconciliation Job from Epic completion checks.
- The landing queue still reports `epic reconciliation pending` while an existing linked reconciliation Job is open.
- Once the linked Job closes, `refresh_auto_state!` clears `reconciliation_job_id`.
- Empty PR-mode reconciliation Jobs still use the existing no-PR / `no_changes` close path rather than cancellation semantics.

## Landing gate

For current Epics with merge trains enabled, child Jobs do not land through the per-Job auto-merge path. They stay approved with `blocked_reason: "waiting for Epic merge-train"` until all open siblings are approved, then land atomically through the train.

For historical Epics whose `reconciliation_job_id` still points to an open standalone reconciliation Job, sibling Jobs continue to receive `blocked_reason: "epic reconciliation pending"` until that Job closes.

## Configuration

`reconciliation_mode` is retained as a legacy compatibility setting for existing standalone reconciliation Jobs and older Epics:

1. **Epic column** (`reconciliation_mode`) — set per Epic in the admin API or via the operator UI.
2. **`.syrus.yml`** (`reconciliation_mode`) — repository-level default.
3. **Built-in default** — `"pr"` for legacy compatibility.

### `.syrus.yml`

```yaml
reconciliation_mode: pr       # legacy standalone PR mode
reconciliation_mode: feedback # legacy standalone feedback mode
reconciliation_mode: none     # skip legacy standalone mode
```

Valid values: `pr`, `feedback`, `none`.

New Epics do not create standalone reconciliation Jobs for any of these values. Merge-train reconciliation runs during landing when merge trains are enabled.

### Per-Epic override

The `reconciliation_mode` column on the `epics` table can be set directly:

```ruby
epic.update!(reconciliation_mode: "none")   # skip legacy standalone mode
epic.update!(reconciliation_mode: "pr")     # preserve legacy PR-mode semantics
epic.update!(reconciliation_mode: nil)      # fall back to .syrus.yml or default
```

The Epic column takes precedence over `.syrus.yml`. Setting it to `nil` restores `.syrus.yml` / default behaviour.

## `work_jobs` scope

`Epic#work_jobs` is a derived scope that excludes the reconciliation Job from the jobs relation. It is used by `complete?`, `stuck?`, and `all_jobs_closed?` so those predicates evaluate only the actual feature jobs. Reconciliation job closure does not block Epic auto-completion.
