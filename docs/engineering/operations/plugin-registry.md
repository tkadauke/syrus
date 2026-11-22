# Operating a plugin registry

Syrus plugin registries are static, versioned directory trees served by an
HTTPS mirror or cloned from a `git+https` URL. The canonical registry at
`https://github.com/tkadauke/syrus-plugins` is created by application code,
enabled by default, and may be disabled but not removed. Administrators may
configure up to ten additional registries. `SYRUS_PLUGIN_REGISTRY_URL` adds a
read-only compatibility source named from its origin.

Registry URLs are administrator-confirmed input. They may not contain URL
credentials, and their destinations must pass the outbound-request guard.
Each registry has an independent cache, refresh lock, stale fallback, and
trust-store cache. A failed or malformed registry therefore does not suppress
results from healthy registries.

The root index.json discovery document has format_version 1, a trust_store
path, and a releases array of relative paths such as
acme_weather/1.2.3.json. Each publisher-prefixed plugin has one directory and
one JSON file per release. Names use the package-compatible
publisher_plugin form.

Every release file contains name, version, description, category, author,
homepage, license, requires_syrus, package_url, package_digest (a
sha256-prefixed digest), signature_url, publisher_key_fingerprint,
trust_label_inputs, and capability_summary. The requires_syrus value is a
RubyGems version requirement. trust_label_inputs records the registry's
auditable classification inputs; the displayed label remains authoritative
from the publisher fingerprint in the trust store.

The trust-store file uses the plugin package trust-store format: publishers
map Ed25519 key fingerprints to official, verified, or community;
revoked_keys lists fingerprints; and revoked_releases lists name, version,
and optional digest tuples. Revoked releases are not discoverable. Publisher
prefix ownership is mandatory. Trust, revocation, and relabeling never cross
registry boundaries. Only the canonical registry may confer `official`;
`official` from another registry is displayed and persisted as `verified`.

Catalog collisions remain visible with their source registry. A bare install
prefers the canonical release for the selected version. If only multiple
non-canonical matches remain, the caller must select a registry explicitly.

Mirrors should return ETag and/or Last-Modified headers. Syrus sends
conditional requests and retains the last valid cache when a refresh fails.
The index may contain only relative paths. Package and signature URLs must use
HTTPS. Package bytes are checked against package_digest, then the detached
signature verifier checks provenance and revocation before staging.

The Go CLI reads SYRUS_PLUGIN_REGISTRY_URL from its own environment and caches
the compatible catalog under the user's cache directory. This lets `syrus
plugin search [TERM]` query either registry transport directly rather than
routing registry content through the configured Syrus instance.

The reusable index starter in `templates/plugin-index` runs `syrus plugin
index-check` for changed releases. The check downloads the package and
signature, verifies digest and publisher provenance, compares manifests,
validates the package, and runs its contract tests against the declared minimum
Syrus release. It emits a single JSON CI summary.
