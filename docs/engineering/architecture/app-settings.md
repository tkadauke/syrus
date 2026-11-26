# App-setting internals

### github_app_registered_at

**Type:** datetime

When the GitHub App was registered. Informational; does not affect runtime behavior.

### github_app_installation_sync_started_at

**Type:** datetime

When the latest GitHub App installation sync attempt started. Used by the admin installation diagnostic and chat MCP diagnostic tool to distinguish a stale or never-run sync from a missing App installation.

### github_app_installation_sync_succeeded_at

**Type:** datetime

When the latest GitHub App installation sync completed successfully.

### github_app_installation_sync_duration_ms

**Type:** integer

Duration of the latest GitHub App installation sync attempt in milliseconds.

### github_app_installation_sync_records_seen

**Type:** integer

Number of installation records returned by GitHub during the latest successful sync attempt.

### github_app_installation_sync_error_class

**Type:** string

Ruby exception class from the latest failed installation sync attempt, cleared after a successful sync.

### github_app_installation_sync_error_message

**Type:** text

Exception message from the latest failed installation sync attempt, cleared after a successful sync.

## Prepared-layer cache mechanics

Entries live in `$SYRUS_DATA_ROOT/prepared-layers/<worker storage key>/<prepare
fingerprint>/`, outside any workflow workspace. The fingerprint already covers
the prepare plan *and* the worker capability environment, so entries that share
one are interchangeable; the storage key stays in the path because a data root
is not always private to one host.

Publication is deduplicated the same way: when an archive carrying this
prepare fingerprint has already been published, the snapshot attaches that
blob instead of uploading a second ~526 MB copy of the same dependency
closure, and `WorkflowSourceSnapshot#purge_prepared_workspace_archive!`
detaches rather than purges while other snapshots still point at the blob.

The source revision is deliberately **not** part of the key. An entry is a
dependency carrier whose source sits at whichever revision built it, and a
checkout that wants a different revision is materialized from the entry and
then moved -- fetching only the objects it is missing, which the git mirror
answers over the LAN. That is what collapses the per-revision cost: production
saw 2 distinct fingerprints in 14 days against 89 published archives of
~526 MB each.

Least-recently-used entries are evicted once a worker is over budget. Eviction
also runs while the data root is in disk trouble regardless of the budget: a
full data root takes the whole worker out of rotation, which is worse than
losing a cached tree. An entry nothing has touched for less than
`PreparedLayerCache::EVICTION_GRACE` is never evicted, which is how a tree in
use by a running grader is protected without holding a lock across process
restarts.

## Workflow-step resource profiles and PSI

Host admission no longer uses `WorkflowStepResourceProfile`; it is measured (memory PSI,
memory headroom and a per-worker concurrency controller) -- see the
multi-worker architecture reference. The profiles remain for diagnostics and
the opt-in per-spawn cgroup budget.

The operator-facing settings and defaults remain in [`config/syrus_docs/app_settings.md`](../../../config/syrus_docs/app_settings.md).
