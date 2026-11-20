# Local Backups

Local Backups is a disabled-by-default plugin that creates sealed recovery
bundles beneath `SYRUS_BACKUP_ROOT` and presents a read-only inventory at
**Admin → Local Backups**. Creation supports an authoritative SQLite or MySQL
database and streams objects through Active Storage, including S3-compatible
services. Scheduling, retention, download, and restore
are separate product stages.

`SYRUS_BACKUP_ROOT` must name an existing absolute directory. The directory
must not be a symlink, contain symlink path components, or contain (or be
contained by) `SYRUS_DATA_ROOT`. Artifact paths are resolved beneath the root;
traversal and symlink escapes are rejected.

The inventory is reconstructed from immutable `manifest.json` files in direct
child artifact directories. Unknown manifest major versions and malformed
manifests are reported as invalid and do not become backup records. Additive
fields in a compatible v1 manifest are accepted. Manifests record SHA-256
checksum metadata and only one-way encryption-key fingerprints, never keys or
other secrets.

Creation takes an installation-wide lease. SQLite uses its online `VACUUM INTO`
operation. MySQL uses a compressed `mysqldump --single-transaction` logical
snapshot, records server and client versions, and refuses non-InnoDB tables.
The snapshot subprocess receives credentials only through its sanitized
environment. Creation records holds for every Active Storage object
selected from that snapshot. A held blob cannot be purged until the attempt
finishes. Object export uses bounded concurrency set by
`SYRUS_BACKUP_OBJECT_CONCURRENCY` (default 4), streams rather than buffering
whole objects, checks recorded size and checksum, and calculates an independent
SHA-256 bundle checksum.
Missing, truncated, or corrupt objects fail the attempt without replacing any
previous artifact.

Before creating a partial artifact, capacity admission requires space for the
estimated sealed bundle, the temporary database snapshot, construction
overhead, and the larger of the configured absolute or percentage reserve.
Set `SYRUS_BACKUP_MIN_FREE_BYTES` and `SYRUS_BACKUP_MIN_FREE_PERCENT` to tune
those reserves. Completed directories are fsynced, atomically renamed from a
hidden sibling partial directory, and made read-only.

Local Backups also supplies the versioned backup artifact-source capability.
Destination plugins consume opaque artifact identities and streams through
that contract; they do not receive arbitrary local filesystem access.
On Docker Compose, `SYRUS_BACKUP_HOST_PATH` selects a host-visible directory
that is separate from the installer's upgrade safety archives. The worker
mounts it read-write and web mounts it read-only. Daily scheduled creation is
enabled with `SYRUS_BACKUP_SCHEDULE_ENABLED=1`; count and age retention use
`SYRUS_BACKUP_KEEP_COUNT` and `SYRUS_BACKUP_KEEP_DAYS`. Pinned artifacts and
the newest valid recovery point are never deleted. Before rejecting a creation
for insufficient capacity, retention gets one opportunity to reclaim eligible
artifacts. Administrators can create, validate, pin, unpin, download, and delete
eligible artifacts from the inventory page. Downloads are audited and support
HTTP byte ranges without loading the archive into Rails memory.

On Kubernetes, provision a dedicated backup PVC. The k3s default is one
backup-owner worker with a `ReadWriteOnce` claim and a `Recreate` rollout; web
pods must not receive write access. Clusters with proven shared-volume support
may use the optional `ReadWriteMany` template. Configure claim capacity and
storage class through the Helm deployment, mount it at `SYRUS_BACKUP_ROOT`, and
set the absolute/percentage reserves so construction stops before PVC
exhaustion. Example topologies live under `config/deploy/kubernetes/`.

For bare-metal systemd installations, use a separate `syrus-backup` service
identity and install `config/deploy/systemd/syrus-backups.tmpfiles` so
`/var/lib/syrus/backups` is mode `0700`. Do not grant the web service write
access; expose only authenticated, bounded download operations to it.

Replication execution and restore remain separate product stages.
