# Local Backups

Local Backups is a disabled-by-default plugin that discovers sealed recovery
bundle manifests beneath `SYRUS_BACKUP_ROOT` and presents a read-only inventory
at **Admin → Local Backups**. Enabling it does not create, delete, download, or
restore backups.

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

Local Backups also supplies the versioned backup artifact-source capability.
Destination plugins consume opaque artifact identities and streams through
that contract; they do not receive arbitrary local filesystem access. Backup
creation, scheduling, retention, download, replication execution, and restore
are separate product stages and are not available from this inventory page.
