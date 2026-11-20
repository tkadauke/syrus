# Local Backups

Local Backups is a disabled-by-default plugin that creates sealed recovery
bundles beneath `SYRUS_BACKUP_ROOT` and presents a read-only inventory at
**Admin → Local Backups**. Creation currently supports an authoritative SQLite
database and Disk Active Storage. Scheduling, retention, download, and restore
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

Creation takes an installation-wide lease, snapshots SQLite with its online
`VACUUM INTO` operation, and records holds for every Active Storage object
selected from that snapshot. A held blob cannot be purged until the attempt
finishes. Blob bytes are streamed from Disk storage, checked against their
recorded size and checksum, and checksummed with SHA-256 for the bundle.
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
Replication execution and restore remain separate product stages.
