# S3 Backup Destination

S3 Backup Destination is a disabled-by-default plugin that copies completed,
immutable Local Backups artifacts to an S3-compatible bucket. It consumes the
versioned backup artifact-source capability and never receives a filesystem
path or snapshots a live database.

Configure a bucket with `SYRUS_BACKUP_S3_BUCKET`, optional
`SYRUS_BACKUP_S3_PREFIX` and `SYRUS_BACKUP_S3_ENDPOINT`, and isolated
credentials in `SYRUS_BACKUP_S3_ACCESS_KEY_ID` and
`SYRUS_BACKUP_S3_SECRET_ACCESS_KEY`. `SYRUS_BACKUP_S3_REGION` defaults to
`us-east-1`. Credentials should be limited to multipart upload, read,
verification, and deletion beneath the configured prefix. Destination
requests use at most `SYRUS_BACKUP_S3_RETRY_LIMIT` SDK retries (default 3).

Each backup UUID maps to one object beneath the destination prefix. Uploads
stream in fixed-size multipart chunks, so memory use is bounded and an
interrupted upload is aborted. Repeated completion delivery reuses an object
only when its backup identity and sealed-source checksum metadata match. The
plugin then streams the remote object through SHA-256 verification; an S3 ETag
alone is never accepted as integrity evidence.

Remote references stored by Local Backups are opaque outside this plugin.
Replication state is recorded independently per destination as uploading,
verified, or failed. Failures are redacted and do not invalidate the local
backup or prevent another destination from running. An in-progress upload
temporarily protects its source from retention. When
`SYRUS_BACKUP_REQUIRE_VERIFIED_REPLICATION=1`, local retention additionally
requires at least one verified destination record before deletion.

Recovery tooling may give the destination a writable IO owned by local
recovery storage. Materialization streams remote bytes into that IO and checks
the complete SHA-256 before the result is eligible for validation or restore;
the destination does not choose or open a local path itself.
