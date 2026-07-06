# Releasing Syrus

A release ships everything Syrus distributes, as one tested set, from a single
manual workflow run:

- **CLI** — `syrus_vX.Y.Z_{darwin,linux}_{amd64,arm64}.tar.gz` + checksums.
- **Desktop apps** — signed, notarized macOS `Syrus-X.Y.Z-{arm64,x64}.dmg` +
  `.zip` + `latest-mac.yml`, and Azure-signed Windows
  `Syrus-Setup-X.Y.Z-{x64,arm64}.exe` + `latest.yml`, plus stable-named
  aliases for the website permalinks (`Syrus.dmg`, `Syrus-Intel.dmg`,
  `Syrus-Setup.exe`).
- **Backend image** — `ghcr.io/tkadauke/syrus-local:X.Y.Z`, built and
  integration-tested in CI, with `:latest` moved to it.
- **GitHub Release `vX.Y.Z`** — auto-generated notes, every artifact above.

Backend upgrades ride app auto-update: a new app version carries a new image
pin (`SYRUS_RELEASE_BUILD=1` writes it into the app's `manifest.json`), and on
the next launch the app offers to update the local backend.

## How to cut a release

**Actions → "Release" → Run workflow.** Pick the **bump** and run. That's it —
the pipeline computes the version, builds and signs everything, and publishes
near-atomically (a draft release flipped live as the last step, rolled back on
any failure — see [the pipeline](#the-pipeline-githubworkflowsreleaseyml)).

| Input | Meaning |
| --- | --- |
| `bump` | `patch` / `minor` (default) / `major`. The version is computed from the higher of the latest release tag and `desktop/package.json`, then bumped. |
| `version` | Optional explicit override, e.g. `v1.2.3` or a pre-release `v1.2.3-beta.1` (auto-flagged as a GitHub pre-release). Overrides `bump`. |
| `dry_run` | Build and stage **everything** (image built + integration-tested, apps **signed + notarized / Azure-signed**, CLI cross-compiled) but publish nothing — no tag, no release, no image push, no `:latest` move. The full rehearsal: the build jobs are identical to a real release, so signing is validated every dry run. The staged artifacts (`staged-mac` / `staged-windows` / `staged-cli`) are downloadable from the run for inspection. |

### The pipeline (`.github/workflows/release.yml`)

```
prepare ─┬─ build-backend (build + bin/test-docker + push :X.Y.Z, NOT :latest)
         ├─ build-cli     (cross-compile tarballs → staged)
         ├─ build-mac     (sign + notarize + staple → staged)
         └─ build-windows (Azure-sign → staged)
                    │  all four must pass
                    ▼
                 publish   (NEAR-ATOMIC draft-release flow:
                            snapshot :latest, bump main (non-fatal),
                            create an invisible DRAFT release with every
                            staged artifact + generated notes, move image
                            :latest → :X.Y.Z, then flip the draft to
                            published as the go-live — and roll back the
                            draft + tag + :latest if anything fails)
                    ▼
             publish-website  (calls the shared deploy-website workflow — stub)
```

Nothing is user-visible until `publish`. The build jobs only *stage* artifacts
and push a *versioned* image tag; if any of them fails, `publish` never runs —
no tag, no release, no moved `:latest`. macOS and Windows build in parallel
(the old create-release 422 race is gone because neither job touches the
release). A dry run skips `publish` and `publish-website` entirely.

`publish` is **near-atomic**, not perfectly atomic. It builds the whole
release as an invisible **draft** first — the tag, every staged asset, and
the generated notes all land inside a draft nobody can see — then moves the
image `:latest` pointer, and only then flips the draft to published
(`gh release edit --draft=false`), a single tiny go-live as the last
irreversible action. If any step fails, a `Roll back on failure` step deletes
the draft release + tag (`gh release delete --cleanup-tag`) and reverts
`:latest` to the digest it snapshotted at the start, so a failed run leaves
**no half-published state**. The one residue is the *versioned* backend image
that `build-backend` already pushed before `publish` ran — a tested,
unreferenced orphan tag (`:latest` never pointed at it), harmless and
overwritten on the next attempt.

### Updating just the website

The website deploys through a **reusable** workflow,
[`.github/workflows/deploy-website.yml`](../.github/workflows/deploy-website.yml),
so the build/deploy logic lives in exactly one place. The release calls it as
its final `publish-website` step (`uses: ./.github/workflows/deploy-website.yml`,
passing the `release_tag`), but you don't need to cut a software release to
refresh the site: the same workflow also runs

- **on demand** — **Actions → "Deploy website" → Run workflow**
  (`workflow_dispatch`), and
- **automatically** — on any `push` to `main` that touches `website/**`.

So a docs fix or copy change redeploys the site on its own, without a version
bump, a tag, or a new set of app builds. (The deploy step is still a **stub** —
the static site under `website/src/` has no in-repo build/host target yet — but
whenever one lands, it lands in that one workflow and all three entry points get
it at once.)

## Versioning convention

Semantic versioning. The pipeline computes the next version and owns it:

- **`minor`** is the default — the normal cadence for a release with features
  and fixes.
- **`patch`** is for hotfix-only releases.
- **`major`** must be chosen explicitly (never automatic) — for breaking
  changes.
- Pre-releases use `vX.Y.Z-beta.N` via the `version` input; electron-updater
  skips pre-releases by default.

`publish` commits the bump to `desktop/package.json` on `main`, so dev builds
and the next release start from the right base. If a branch-protection rule
blocks that push, the release still succeeds and the *tag* carries the version
forward — the next release self-corrects. (To let CI push the bump, allow the
release workflow to bypass protection on `main`.)

## Release notes

Auto-generated by GitHub from the merged PRs since the last release
(`gh release create --generate-notes`). Edit the release afterward if you want
to add highlights. For richer, grouped prose you can pre-write notes locally
with `bin/release-notes vX.Y.Z` (Claude-authored) and paste them in.

## One-time setup

| Item | Where | Notes |
| --- | --- | --- |
| Apple Developer Program membership | developer.apple.com | $99/yr; identity verification can take days |
| Developer ID Application certificate | Xcode → Manage Certificates → **Developer ID Application** | Export `.p12` with the private key. The type must literally read **"Developer ID Application"** — an "Apple Development" cert signs locally then fails notarization on every binary. |
| `CSC_LINK` | repo secret | base64 of the `.p12` (`base64 -i cert.p12`) |
| `CSC_KEY_PASSWORD` | repo secret | the `.p12` export password |
| App Store Connect API key (`.p8`) | appstoreconnect.apple.com → Integrations | Developer role suffices for notarytool |
| `APPLE_API_KEY_P8` / `APPLE_API_KEY_ID` / `APPLE_API_ISSUER` | repo secrets | the key contents + its ids |
| Azure Trusted Signing | see [`windows-signing.md`](./windows-signing.md) | `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` (secrets) + the four `AZURE_SIGN_*` identifiers (secrets or repo variables) |
| GHCR `syrus-local` package visibility | github.com/users/tkadauke/packages | **must be public** — every end user's install pulls it anonymously |

Validate both signing paths (Apple **and** Azure) without cutting a release
with a **dry-run release**: **Actions → "Release" → Run workflow → check
`dry_run`**. It builds + signs + notarizes / Azure-signs every artifact and
stages them (`staged-mac` / `staged-windows` / `staged-cli`, downloadable from
the run) but publishes nothing. The Apple credentials can also be validated
locally (below).

## Signing / building locally

`bin/publish-image X.Y.Z` (image) and `bin/release-desktop` (via
`bin/signing-env`) reproduce the exact CI build on your own machine — useful
for verifying signing or image changes without spending a release run. These
stay as local tools; the canonical release path is the CI workflow above.

For a local **signed + notarized** macOS build, `bin/signing-env` reads the
same credentials CI gets from repo secrets, from `~/.config/syrus/` instead:

1. `~/.config/syrus/mac-signing.env` (`chmod 600`), dotenv-style:

   ```
   CSC_LINK=<base64 of the .p12 — base64 -i cert.p12>
   CSC_KEY_PASSWORD=<the .p12 export password>
   APPLE_API_KEY_ID=<from the App Store Connect API key>
   APPLE_API_ISSUER=<from the same page>
   ```

2. `~/.config/syrus/apple-api-key.p8` (`chmod 600`) — the App Store Connect
   API key file itself (downloadable once from App Store Connect).

With both present, `bin/release-desktop` signs and notarizes exactly like the
CI pipeline; without them it falls back to an unsigned local build. Neither
file is committed — they play the role repo secrets play in CI. Windows local
signing is documented in [`windows-signing.md`](./windows-signing.md)
(`~/.config/syrus/windows-signing.env`).

## Why unsigned releases are blocked

The pipeline refuses to publish a non-dry release without signing secrets:

- macOS Sequoia shows unsigned downloads a hard "Apple could not verify…"
  block.
- electron-updater on macOS rides Squirrel.Mac, which refuses to install an
  update into an unsigned or differently-signed app — one unsigned release
  would strand the installed base off the update path.
- Windows SmartScreen penalizes unsigned installers, and the pipeline never
  ships an unsigned `.exe`.

## When a run goes red

Go straight to [`release-troubleshooting.md`](./release-troubleshooting.md) —
a symptom-indexed runbook. The credential preflights fail in seconds with
self-explanatory `::error` messages; those are setup mistakes, not pipeline
bugs.
