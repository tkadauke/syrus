# Local Backups

The Local Backups plugin is bundled with Syrus and disabled by default. Enable
it from Admin → Plugins after configuring `SYRUS_BACKUP_ROOT` as an absolute,
persistent directory outside `SYRUS_DATA_ROOT`.

This initial capability is read-only. The Admin → Local Backups page scans
sealed v1 manifests below the configured root and reconstructs the inventory
when database rows are missing. It does not yet create, schedule, download,
delete, or restore backups.

The root and all discovered artifact paths are containment checked. Symlink
roots, symlink escapes, relative roots, and roots nested with the primary data
directory are rejected. Invalid, unsealed, or unknown-version manifests are
reported but never advertised as recoverable backups.

Manifests contain checksums and non-secret encryption-key fingerprints. They
must never contain encryption keys, credentials, access tokens, database
passwords, signed URLs, or environment dumps.
