# Epic Reconciliation Mode

Epic reconciliation automatically creates a synthesizing Job after all sibling Jobs in an Epic have been implemented. The reconciliation Job reviews the combined changes across siblings for inter-Job consistency, shared-surface regressions, and cross-cutting concerns that individual reviewers may not catch.

## How it works

When an Epic goes `in_progress` and has 2 or more child Jobs, Syrus creates a **reconciliation Job**. This Job:

1. **Depends on all sibling Jobs** — it cannot start until every sibling Job has cleared the landing queue (approved and unblocked).
2. **Runs a review prompt** — the agent reads the combined diff across all sibling branches and checks for consistency, naming conflicts, API contract mismatches, shared migration conflicts, and cross-cutting concerns.
3. **Blocks landing** — sibling Jobs cannot land while the reconciliation Job is open. The reconciliation Job itself is not blocked; only siblings are held.
4. **Auto-clears** — when the reconciliation Job closes (merged or no-changes), the Epic's `reconciliation_job_id` is cleared and sibling Jobs can proceed to landing.

## Reconciliation Job creation

The reconciliation Job is a `kind=direct` Job attached to the Epic. It is created:

- When `Epic#start!` or `Epic#override_state!("in_progress")` runs and the Epic already has 2+ child Jobs.
- When a new child Job is added to an already `in_progress` Epic and the total sibling count reaches 2.

The Job is idempotent — Syrus will not create a second reconciliation Job while one is already open (`reconciliation_job_id` is set on the Epic).

## Landing gate

While `epic.reconciliation_job_id` is present and the reconciliation Job is open, sibling Jobs in the Epic receive a `blocked_reason` of `"epic reconciliation pending"` in the landing queue. The reconciliation Job itself is exempt from this gate.

Once the reconciliation Job closes (regardless of closure reason), `refresh_auto_state!` clears `reconciliation_job_id` and sibling Jobs can proceed to landing normally.

When a PR-mode reconciliation Job produces no additional diff against its effective stack parent, Syrus treats that as a successful empty reconciliation. The `pr_open` step records a no-PR reason on the Workflow, skips PR creation, and closes the Job with `closure_reason: no_changes` so dependent Jobs and Epic completion can proceed. If a duplicate empty reconciliation PR already exists, Syrus comments on it, closes it unmerged, and closes the Job as `no_changes`.

## Configuration

Reconciliation mode is resolved with this precedence:

1. **Epic column** (`reconciliation_mode`) — set per Epic in the admin API or via the operator UI.
2. **`.syrus.yml`** (`reconciliation_mode`) — repository-level default.
3. **Built-in default** — `"pr"` (create a reconciliation Job).

### `.syrus.yml`

```yaml
reconciliation_mode: pr      # create reconciliation Job (default)
reconciliation_mode: feedback # create reconciliation Job in feedback mode
reconciliation_mode: none    # skip reconciliation entirely
```

Valid values: `pr`, `feedback`, `none`.

When `reconciliation_mode: none` is set (via Epic column or `.syrus.yml`), no reconciliation Job is created and siblings can land independently.

### Per-Epic override

The `reconciliation_mode` column on the `epics` table can be set directly:

```ruby
epic.update!(reconciliation_mode: "none")   # disable for this Epic
epic.update!(reconciliation_mode: "pr")     # re-enable for this Epic
epic.update!(reconciliation_mode: nil)      # fall back to .syrus.yml or default
```

The Epic column takes precedence over `.syrus.yml`. Setting it to `nil` restores `.syrus.yml` / default behaviour.

## `work_jobs` scope

`Epic#work_jobs` is a derived scope that excludes the reconciliation Job from the jobs relation. It is used by `complete?`, `stuck?`, and `all_jobs_closed?` so those predicates evaluate only the actual feature jobs. Reconciliation job closure does not block Epic auto-completion.
