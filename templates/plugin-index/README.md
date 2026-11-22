# Syrus plugin index

This repository is a reviewable registry of signed Syrus plugin releases. A
publisher submits one JSON file at `publisher_plugin/version.json` and adds its
path to `index.json`. CI runs `syrus plugin index-check` against every changed
release before review.

## Submission and review rules

- Anyone may submit a publisher-prefixed plugin. The prefix must identify the
  publisher represented by a key in `trust-store.json`; maintainers approve new identities and keys.
- **Community** releases receive automated checks plus one maintainer review.
- **Verified** publishers additionally receive identity/ownership and changed-capability reviews.
- **Official** releases require two maintainer approvals, including capability review.
- Packages are immutable. Publish a new version instead of replacing an asset.

Revoke a compromised key in `revoked_keys`. Revoke one release in
`revoked_releases` with its name, version, and digest. Merge revocations
promptly, remove affected releases from `index.json`, and preserve the records
in git history for auditability.

```sh
GITHUB_TOKEN=... syrus plugin publish . --key /secure/key.json \
  --repository OWNER/PLUGIN --index-repository OWNER/INDEX --submit
```

Omit `--submit` to print the entry and manual instructions. The token is read
only from `GITHUB_TOKEN`; it is never printed or stored.
