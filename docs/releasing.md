# Releasing Syrus

A release ships everything Syrus distributes, as one tested set, from a single
manual workflow run:

- **CLI** — `syrus_vX.Y.Z_linux_{amd64,arm64}.tar.gz` + checksums. **Linux only**:
  it's the sole platform with no desktop app, so the tarballs are the only way
  CI / servers / headless boxes get the CLI. macOS + Windows users get the CLI
  bundled + auto-installed by the desktop app, so darwin tarballs were dropped
  (add them back to `bin/release-cli` if a CLI-only-on-Mac audience appears).
- **Desktop apps** — one universal, notarized macOS build (Apple Silicon +
  Intel) and an Azure-signed Windows x64 build (runs on arm64 Windows via
  emulation). Humans download the stable **`Syrus.dmg`** / **`Syrus-Setup.exe`**
  website permalinks; the app's **auto-update** rides `Syrus-X.Y.Z-universal.zip`
  + `latest-mac.yml` (macOS, via Squirrel.Mac) and `Syrus-Setup-X.Y.Z-x64.exe` +
  `latest.yml` (Windows), plus `.blockmap`s for delta downloads. The *versioned*
  dmg is not shipped — it would be a byte-identical twin of `Syrus.dmg`.
- **Backend image** — `ghcr.io/tkadauke/syrus-backend:X.Y.Z`, built and
  integration-tested in CI, with `:latest` moved to it.
- **GitHub Release `vX.Y.Z`** — Claude-written highlights over GitHub's
  mechanical changelog (see [Release notes](#release-notes)), every artifact above.

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
| `bump` | `patch` / `minor` (default) / `major`. The version is computed by bumping the latest release tag (`desktop/package.json` stays a `0.0.0` sentinel, so you never hand-set a version). |
| `version` | Optional explicit override, e.g. `1.2.3` or a pre-release `1.2.3-beta.1` (auto-flagged as a GitHub pre-release). A leading `v` is accepted but not needed. Overrides `bump`. |
| `dry_run` | Build and stage **everything** (image built + integration-tested, apps **signed + notarized / Azure-signed**, CLI cross-compiled) but publish nothing — no tag, no release, no image push, no `:latest` move. The full rehearsal: the build jobs are identical to a real release, so signing is validated every dry run. The staged artifacts (`staged-mac` / `staged-windows` / `staged-cli`) are downloadable from the run for inspection. |
| `review_notes` | Hold the release as a **draft** so you can read the (LLM-written) notes before it goes public. Everything runs — build, sign, generate notes, move image `:latest` — but the final draft→published flip is skipped; you edit the notes and click **Publish** in the GitHub UI when ready. Default off (auto-publish). |

### The pipeline (`.github/workflows/release.yml`)

`release.yml` is **thin**: it owns the release-specific bits — the version calc
(`prepare`) and the near-atomic go-live (`publish`) — and delegates the actual
build+sign of every shippable component to a **shared reusable module**,
[`.github/workflows/_build-app.yml`](../.github/workflows/_build-app.yml). That
same module is called by the Test build pipeline (`test-build.yml`), so the two
can never drift: a test build and a release build every component the same way,
byte-for-byte, differing only in the inputs each caller passes (image tags,
cache prefix, whether to push, whether to stage the auto-update feed, artifact
names/retention). See [The shared build module](#the-shared-build-module).

```
prepare ── build  (uses ./.github/workflows/_build-app.yml — the SHARED spine):
                 ┌─ build-backend (MATRIX, native per arch — NO QEMU:
                 │                  amd64 on ubuntu-latest, arm64 on ubuntu-24.04-arm;
                 │                  each builds its arch, runs bin/test-docker on it,
                 │                  then pushes that arch BY DIGEST) ──┐
                 │                                                     ▼
                 │                       merge-backend (imagetools create → the
                 │                       multi-arch :X.Y.Z tag; NOT :latest)
                 ├─ build-cli     (cross-compile tarballs → staged)
                 ├─ build-mac     (sign + notarize + staple → staged)
                 └─ build-windows (Azure-sign → staged)
                    │  the whole build spine must pass
                    ▼
                 publish   (NEAR-ATOMIC draft-release flow:
                            snapshot :latest, create an invisible DRAFT
                            release with every staged artifact + generated
                            notes, move image :latest → :X.Y.Z, then flip
                            the draft to published as the go-live — and roll
                            back the draft + tag + :latest if anything fails)
                    ▼
             publish-website  (calls the shared deploy-website workflow — stub)
```

### The shared build module

`.github/workflows/_build-app.yml` is a `workflow_call` module that builds and
signs the whole shippable set — backend image (native per-arch matrix →
multi-arch manifest), CLI tarballs, the notarized macOS app, and the Azure-signed
Windows installer — and stages them as run artifacts. It owns none of the
release-specific plumbing: version computation stays in each caller's `prepare`
job, and publishing (draft release, `:latest` move, notes, website) stays in
`release.yml`. Callers reach it as a single job (`build:`) and pass `secrets:
inherit` so it gets every signing secret; it declares only `contents: read` +
`packages: write`.

The two callers differ **only** in inputs:

| Input | Release | Test build |
| --- | --- | --- |
| `version` | `X.Y.Z` | `X.Y.Z-test.N` |
| `image_primary_tag` | `X.Y.Z` | `test-<short-sha>` |
| `image_extra_tag` | — | `test-<X.Y.Z-test.N>` |
| `backend_image_pin` | `…syrus-backend:X.Y.Z` | `…syrus-backend:test-<X.Y.Z-test.N>` |
| `cache_ref_prefix` | `…syrus-backend:buildcache` | `…syrus-backend:buildcache-test` |
| `push_image` | `dry_run == false` | `true` |
| `stage_update_feed` | `true` | `false` |
| `artifact_prefix` | `staged` | `test-staged` |
| `artifact_retention_days` | 7 | 14 |
| `run_integration_tests` / `build_windows` | `true` | the dispatch inputs |

To change how ANY component is built or signed, edit the module once; both
entry points pick it up. To change what a release vs. a test build produces,
change the input a caller passes.

Nothing is user-visible until `publish`. The build jobs only *stage* artifacts
and push a *versioned* image tag; if any of them fails, `publish` never runs —
no tag, no release, no moved `:latest`. macOS and Windows build in parallel
(the old create-release 422 race is gone because neither job touches the
release). A dry run skips `publish` and `publish-website` entirely, **but still
builds and integration-tests both arches natively** — a faithful rehearsal, no
QEMU, publishing nothing (no digest push, no manifest, no tag).

**The backend build is native, per-arch, no QEMU.** `build-backend` is a matrix:
amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm` (GitHub's arm64 runners,
GA for private repos since 2026-01-29). Each leg builds its own arch on a real
CPU, runs `bin/test-docker` against it (so **both** arches are integration-tested,
not just one), and on a real run pushes that arch *by digest*; `merge-backend`
then `imagetools create`s the two digests into the multi-arch `:X.Y.Z` tag. This
replaced a single-runner `buildx --platform amd64,arm64` build whose arm64 half
ran ~40 min under QEMU. The BuildKit registry cache is keyed per arch
(`:buildcache-amd64` / `:buildcache-arm64`) so the legs don't clobber each
other. **Prerequisite:** the account/plan must have arm64 hosted runners enabled
(standard tier); a wrong/absent `ubuntu-24.04-arm` label queues forever.

`publish` is **near-atomic**, not perfectly atomic. It builds the whole
release as an invisible **draft** first — the tag, every staged asset, and
the generated notes all land inside a draft nobody can see — then moves the
image `:latest` pointer, and only then flips the draft to published
(`gh release edit --draft=false`), a single tiny go-live as the last
irreversible action. If any step fails, a `Roll back on failure` step deletes
the draft release + tag (`gh release delete --cleanup-tag`) and reverts
`:latest` to the digest it snapshotted at the start, so a failed run leaves
**no half-published state**. The one residue is the *versioned* backend image
that `merge-backend` already assembled before `publish` ran — a tested,
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

## Test builds

**Actions → "Test build" → Run workflow** (pick the branch), or from a
terminal:

```
gh workflow run test-build.yml --ref <branch>
```

A test build ([`.github/workflows/test-build.yml`](../.github/workflows/test-build.yml))
deterministically builds **every** shippable component from any ref — including
a feature branch — without publishing anything:

- **Backend image** — built natively per arch (same no-QEMU matrix as the
  release), integration-tested with `bin/test-docker`, and **pushed to GHCR**
  under two twin tags: `ghcr.io/tkadauke/syrus-backend:test-<X.Y.Z-test.N>`
  (the badge-consistent tag the installers pin) and `:test-<short-sha>` (commit
  traceability). Both shapes are guarded (`test-` prefix, never `latest`,
  never semver), so a test image can never collide with or shadow a release
  tag. `:latest` is never touched, and
  test builds write their own registry build-cache tags
  (`buildcache-test-<arch>`) so a divergent branch can't evict the warm cache
  the next real release depends on.
- **Desktop apps** — a **signed + notarized** macOS DMG and (unless you
  uncheck `build_windows`) an **Azure-signed** Windows installer, versioned
  `X.Y.Z-test.<run-number>` (the next patch over the same tag/`package.json`
  base a release uses) so a test build can never be mistaken for a release.
  Both installers pin the `test-<X.Y.Z-test.N>` image in their `manifest.json`
  (registry addressing), and the image itself bakes the app-style version as
  `SYRUS_VERSION`, so the in-app badge reads identically for both halves:
  `app 0.1.4-test.1 · backend 0.1.4-test.1`. The installers build in
  **parallel** with the backend image (the pin is a string, not a pull); the
  run only succeeds when the tag was also pushed and verified, so a downloaded
  test installer from a green run installs end-to-end.
- **CLI tarballs** — the same `bin/release-cli` build as a release
  (`go test ./...` gate, linux/amd64 + arm64 tarballs, `SHA256SUMS-cli.txt`).

Auto-update is disarmed in **both directions**. Release installs never see a
test build: the workflow stages and publishes no update-feed files. And a test
install never replaces itself: a signed test build still carries the baked-in
GitHub Releases feed, and semver orders `X.Y.Z-test.N` *below* `X.Y.Z`, so an
armed updater would silently swap the pinned evaluation for the next published
release — the app therefore skips auto-update entirely for `-test.` versions
(`desktop/electron/appUpdates.ts`). Graduating a test install to a release is
a deliberate manual reinstall.

The built artifacts land as **workflow-run artifacts** — `test-staged-mac`
(the versioned `.dmg`), `test-staged-windows` (the versioned Setup `.exe`),
and `test-staged-cli` (the CLI tarballs + checksums) on the run's Summary
page, kept for **14 days**. They are deliberately **not** attached to a GitHub
Release and carry no stable-name aliases (`Syrus.dmg` / `Syrus-Setup.exe` are
the website permalinks — releases only) and no auto-update feed files: the
workflow runs with `contents: read` permissions, so creating a tag or Release
is structurally impossible.

| Input | Meaning |
| --- | --- |
| `run_integration_tests` | Run `bin/test-docker` against each built arch before pushing (default on). Uncheck for a faster untested image. |
| `build_windows` | Also build + sign the Windows installer (default on). |

**Test build vs. `dry_run`:** a dry-run *release* is a rehearsal — it builds
and signs everything but pushes **nothing**, so its installers pin an image
tag that never exists. A *test build* always pushes the test-tagged image,
so its artifacts are actually usable: install the DMG, and the app pulls and
runs the exact backend built from your branch. Use `dry_run` to validate the
release pipeline itself; use a test build to hand someone a working build of
unmerged work.

### Side-by-side with a release (channels)

A test build installs as **`Syrus Test.app`** (Windows: `Syrus Test`) and runs
**beside** a production release — install one without touching the other. This
is what makes Syrus-develops-Syrus practical. Every namespaced resource forks
off a single build-time **channel** bit (`stable` for releases, `test` for a
test build or a local dev build):

| Resource | Stable (release) | Test build |
| --- | --- | --- |
| App bundle / name | `Syrus.app` | `Syrus Test.app` |
| macOS bundle id / AUMID | `app.syrus.desktop` | `app.syrus.desktop.test` |
| Settings (userData) | `…/Application Support/Syrus` | `…/Syrus Test` |
| Backend Compose project | `syrus` | `syrus-test` |
| Docker volumes | `syrus_syrus-data`, `…-search` | `syrus-test_syrus-data`, `…-search` |
| Default port | `3000` | `3001` |
| State dir | `~/.syrus/local` | `~/.syrus/local-test` |
| Credentials file | `~/.syrus/credentials` | `~/.syrus/credentials.test` |
| CLI binary | `~/.local/bin/syrus` | `~/.local/bin/syrus-test` |
| Icon / in-app | terracotta mark | amber TEST-ribbon icon + amber TEST pill + macOS tray `TEST` |

The channel is baked at packaging time: the Release workflow passes
`channel: stable`, the Test-build workflow passes `channel: test`, and a local
`npm --prefix desktop run build` (version `0.0.0`) is `test`. The CI threads it
through the shared [`_build-app.yml`](../.github/workflows/_build-app.yml)
module to electron-builder overrides (product name, appId, icon, DMG title,
NSIS shortcut). At runtime the app forks its own userData/lock via
`app.setName()` before the settings store is created — electron-builder's
`-c.productName` renames the `.app` bundle but **not** the bundled
`package.json`, and `app.getName()` (which drives userData and the
single-instance lock) reads the latter, so the rename alone is not enough.

Consequences worth knowing:

- **Fully isolated backends.** The two stacks are separate Docker Compose
  projects with separate databases and encryption keys, so a test build cannot
  corrupt production data. Each channel does credential setup once.
- **Polling starts paused on a test stack.** So it does not race production to
  file Jobs on the same repos, a fresh test backend boots with repository
  polling paused (`SYRUS_BOOT_POLLING_PAUSED`, seeded once). Unpause it from
  the admin console when you intend the test stack to work real repositories.
- **The CLI forks too.** A test build installs `syrus-test`, which reads
  `~/.syrus/credentials.test` — so `syrus-test jobs` talks to the test backend
  while plain `syrus` stays on production. One Go binary resolves its profile
  from the flag `--profile test`, `SYRUS_PROFILE=test`, or its own name, so
  `syrus --profile test` runs the production binary against the test backend.
- **Uninstalling one never touches the other.** `uninstall.sh --channel test`
  removes only the test stack, app, CLI, and settings (and leaves the
  stable-only Claude skill alone).
- **Reset Test Setup (test builds only).** The app-name menu of a test build
  has a **Reset Test Setup…** item — a "clean slate" for re-exercising the
  initial onboarding. It tears down the test backend stack + its data volume,
  deletes `~/.syrus/local-test` and `~/.syrus/credentials.test`, resets the
  test app settings, and relaunches into setup. A confirmation dialog spells
  out exactly what is removed. It is gated to the test channel and never
  appears on — or touches — a production install; downloaded Docker images are
  kept so the next setup is fast. This is the heavy complement to **Run Setup
  Again…** (present on both channels), which only re-picks where Syrus runs and
  keeps your data and credentials.

## Versioning convention

Semantic versioning, **tag-driven**. The git tag is the source of truth; the
pipeline computes the next version by bumping the newest `vX.Y.Z` tag:

- **`minor`** is the default — the normal cadence for a release with features
  and fixes.
- **`patch`** is for hotfix-only releases.
- **`major`** must be chosen explicitly (never automatic) — for breaking
  changes.
- Pre-releases use `X.Y.Z-beta.N` via the `version` input; electron-updater
  skips pre-releases by default.

`desktop/package.json` stays pinned at `0.0.0` — a dev sentinel you never
hand-edit. Each build job stamps the computed version in with
`npm version "$VERSION"` before packaging, so the shipped apps and the image
carry the real number, but **nothing is committed back to `main`**: the next
release just recomputes from the newest tag. That means no version-bump
commit, no branch-protection carve-out for CI, and no manual version bookkeeping
— pick a `bump`, and the tag does the rest.

## Deployment stage tags

Three **moving** git tags track where each released commit stands in the deployment pipeline. The Syrus deployment stage poller reads these tags to show per-Job deployment status in the UI.

| Tag | Advanced by | Meaning |
|---|---|---|
| `staging` | `bin/deploy --staging` after a successful rollout | Deployed to the staging cluster |
| `production` | `bin/deploy --production` after a successful rollout | Deployed to the production cluster |
| `release` | `.github/workflows/release.yml` after `gh release edit … --draft=false` | Published as a public GitHub Release |

These are stable pointers — not the versioned `vX.Y.Z` release tags. `staging` and `production` point to whatever `HEAD` was in the Syrus repo when `bin/deploy` last ran. `release` is fast-forwarded to the version tag's commit once the release is published (with `continue-on-error: true` so a tag-push hiccup never triggers the release rollback path).

## Release notes

**Claude-written highlights over a mechanical changelog** — the hybrid most
projects converge on. The pipeline first lets GitHub generate the mechanical
merged-PR list (`--generate-notes`, which is hallucination-proof: real PRs,
correct attribution), then `bin/release-notes` writes grouped *highlights*
(Highlights / Desktop app / Web app / CLI / Docker & deployment / Fixes /
Internal) from the commit history and prepends them, so the release reads:
curated prose → **Full changelog**. The generator uses the Anthropic API in CI
(the `CLAUDE_API_KEY` secret) and the local `claude` CLI on a maintainer's
laptop; it's non-fatal — if the key is missing or the API errors, GitHub's
mechanical notes stand.

**Should a human review them?** Fully-automated notes are unusual for
user-facing prose (hallucination, misattribution, and especially security
phrasing are where teams keep a human in the loop). Syrus is private and
low-stakes, so **auto-publish is the default** and notes stay editable after
the fact. When you want the human beat, check **`review_notes`** at dispatch:
the release is built and its notes generated, but it's left as a **draft** for
you to read and Publish. This is the classic draft → review → publish flow, and
it costs nothing because the pipeline already builds a draft.

To regenerate notes on your own machine: `bin/release-notes vX.Y.Z` (writes
`dist/releases/<version>/RELEASE_NOTES.md`) or `--stdout` to print them.

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
| GHCR `syrus-backend` package visibility | Package settings → Change visibility | **must be public** — every end user's install pulls it anonymously. New packages are private; flip it once after the first CI publish creates it. |

**No GHCR token needed.** The backend image publishes with the workflow's
built-in `GITHUB_TOKEN` — no PAT, no `GHCR_TOKEN` secret. This works because the
`syrus-backend` package is **connected** to this repo: a package born from a CI
publish connects automatically (reinforced by the `org.opencontainers.image.source`
label in the Dockerfile), which lets the repo's `GITHUB_TOKEN` push it, move
`:latest`, and write the `:buildcache` (all the same package). The only GHCR
one-time action is making the package **public** after it first appears. (If a
package ever pre-exists *unconnected* — e.g. created by a laptop `bin/publish-image`
run — connect it manually via *Package settings → Manage Actions access → Add
Repository → `tkadauke/syrus` → Write*; see
[`release-troubleshooting.md`](./release-troubleshooting.md#62-publish-job-failures).)

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
