# Plugin desired-state artifacts

External plugin releases are stored on the primary Active Storage service under
the content-addressed key `plugins/artifacts/<sha256>`. The digest is the
lowercase SHA-256 of the archive bytes; uploads whose bytes or size do not match
their release record are rejected. Bundled plugins are not members of the
external desired set and do not require an archive.

The control plane publishes the enabled desired set at these well-known keys:

- `plugins/desired/manifest.json`
- `plugins/desired/manifest.json.sig`

The JSON contains `schema_version`, a monotonically increasing `revision`, and
the ordered external plugin entries (`name`, `version`, `digest`, `size`,
`roles`, and `fleet_quarantined`). Publication checks that every referenced
archive exists, writes the detached signature, and writes the manifest last.
Readers therefore treat the manifest as the commit point.

Generate an Ed25519 key with `PluginDesiredState::SigningKey.generate!` from a
Rails console. The private key is encrypted in the singleton application
settings record. Distribute the returned PEM public key to every pre-boot sync
process as `SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY`; never distribute the private key.
Generate and distribute the key before adding the first desired installation.
Committed desired-state changes enqueue publication on the `control_plane`
queue, so a missing key or storage outage is recorded as a failed, retryable job
instead of making the already-committed database write appear to have failed.

To verify a download, base64-decode the `.sig` object and verify it as an
Ed25519 signature over the exact `manifest.json` bytes. Reject the desired set
if the signature fails, its schema version is unsupported, any archive's byte
count differs from `size`, or its SHA-256 differs from `digest`. Retain the
last-known-good installed set on any rejection.

Administrators can inspect the database-backed desired set and current
revision with `GET /api/v1/admin/plugin_desired_state` using the normal admin
bearer token.
