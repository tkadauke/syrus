# Desktop release troubleshooting

`.github/workflows/release.yml` went red. This doc gets you from the
red X to a cause in minutes: find your error string in the triage table,
jump to the section, run the Check, apply the Fix. It covers the macOS
signing/notarization path (`CSC_LINK` + notarytool) and the Windows Azure
Artifact Signing path (both live in `release.yml` — `build-mac` and
`build-windows` — which now run in **parallel**;
`.github/workflows/sign-windows-test.yml` is the manual-dispatch harness
for proving the Azure setup without cutting a release). Setup docs live in
[`releasing.md`](./releasing.md) and [`windows-signing.md`](./windows-signing.md);
this doc assumes setup was once working.

The pipeline is **manually dispatched** (`workflow_dispatch`) — you pick a
`bump` (patch/minor/major, default minor) or an explicit `version`, and an
optional `dry_run`. There is no tag trigger; `prepare` computes the version
from the higher of the latest tag and `desktop/package.json`, then guards
that the tag/release don't already exist. The four build jobs (`build-image`,
`build-cli`, `build-mac`, `build-windows`) each produce **staged** artifacts
and push only a *versioned* backend image — never `:latest`. Only the final
`publish` job creates the tag + GitHub Release, uploads every staged asset,
moves the image `:latest` pointer, and commits the version bump to main. If
any build fails, `publish` never runs — no release, no half-shipped state.

Two orientation facts before you grep:

- The mac job's heavy step is **"Build, sign, and notarize"** — it runs
  electron-builder with `--publish never`, so it signs, notarizes, and
  staples but does **not** upload anything. A separate **"Stage macOS
  artifacts"** step copies the outputs; the `publish` job uploads them
  later. A failure in `build-mac` therefore leaves the release untouched.
- electron-builder's default failure mode for bad signing config is a
  **silent skip, not an error** — the build goes green and ships an
  unsigned app. The workflow's guard and verify steps exist to catch
  this; know the skip strings anyway ([6.1](#61-green-build-unsigned-artifact)).

## 1. 60-second triage

Grep the failed run's log for the string in column one.

| Grep for | Most likely cause | Go to |
| --- | --- | --- |
| `tag vX.Y.Z already exists` / `GitHub release vX.Y.Z already exists` | computed version collides with a prior release | [2](#2-guard-failures-the-deliberate-reds) |
| `Signing secrets missing` | `CSC_LINK` / `APPLE_API_KEY_P8` repo secrets absent | [2](#2-guard-failures-the-deliberate-reds) |
| `Env CSC_LINK is not correct, cannot resolve` | base64 mangled (newlines, lost padding) | [3.2](#32-mangled-csc_link-or-wrong-p12-password) |
| `MAC verification failed during PKCS12 import` | wrong `CSC_KEY_PASSWORD` or corrupted p12 | [3.2](#32-mangled-csc_link-or-wrong-p12-password) |
| `not signed with a valid Developer ID certificate` | wrong cert type in `CSC_LINK` | [3.1](#31-wrong-certificate-type) |
| `errSecInternalComponent` / hang at `signing file=` | runner keychain lock / partition list | [3.3](#33-keychain-hangs-on-the-runner) |
| `status: Invalid` (notarytool) | notarization rejected — pull the developer log | [4.1](#41-invalid-verdict-pull-the-developer-log) |
| `get-task-allow` / `hardened runtime` / `secure timestamp` | entitlements / nested-binary signing | [4.2](#42-entitlements-and-hardened-runtime) |
| No output for 30+ min at the notarize phase | Apple notary backlog, not your config | [4.3](#43-hangs-and-timeouts) |
| `The staple and validate action failed! Error 65` | stapling a mutated artifact, or CDN lag | [4.4](#44-stapler-failures) |
| `skipped macOS application code signing` | silent skip — no usable identity | [6.1](#61-green-build-unsigned-artifact) |
| `skipped macOS notarization` | silent skip — notarize creds absent | [6.1](#61-green-build-unsigned-artifact) |
| `Azure signing configuration missing:` (release) / `Missing secrets/variables:` (test harness) | Azure secrets/vars not configured | [5](#5-windows-azure-artifact-signing) |
| `No match was found for the specified search criteria for the provider 'NuGet'` | PSGallery bootstrap flake | [5.1](#51-module-install-failures) |
| `being used by another process` / `SignTool failed with exit code 3` | concurrent-signing race | [5.2](#52-the-concurrent-signing-race) |
| `Status: 403 (Forbidden)` (codesigning.azure.net) | SP role / identity validation / name mismatch | [5.3](#53-403-forbidden) |
| `AADSTS` | bad `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` | [5.3](#53-403-forbidden) |
| `is not validly signed (status:` | our verify step caught a bad/unsigned exe | [5.4](#54-publishername-and-cn-mismatches), [5.6](#56-timestamping) |
| Windows 403 after months of green, no config diff | identity validation expired (2-year clock) | [5.5](#55-identity-validation-expiry) |
| `timestamp.acs.microsoft.com` errors | flaky ACS timestamp server | [5.6](#56-timestamping) |
| `no staged artifacts to publish` | a build job produced no assets to upload | [6.2](#62-publish-job-failures) |
| `imagetools create` failure moving `:latest` | GHCR packages-write permission / auth | [6.2](#62-publish-job-failures) |
| `Could not push the version bump` | branch protection blocked the bump (non-fatal) | [6.2](#62-publish-job-failures) |
| `Cannot find latest-mac.yml` (client logs) | broken/partial update feed | [6.3](#63-update-feed-integrity) |

Nothing matched? Decide which of the three buckets you're in via
[local reproduction](#7-reproduce-locally-to-bisect): credentials, CI
environment, or external service.

## 2. Guard failures (the deliberate reds)

Several early steps fail fast with explicit `::error` messages. These are
the workflow working as designed, not bugs:

1. **`tag vX.Y.Z already exists`** / **`GitHub release vX.Y.Z already
   exists`** (`prepare` job, "Guard: tag and release are not already
   taken") — the version `prepare` computed (from the higher of the latest
   tag and `desktop/package.json`, plus your `bump`) collides with a
   release that already shipped. This is not a re-tag problem — nothing is
   tagged until `publish`. Fix: re-dispatch with a different `bump`, or
   pass an explicit `version` override that isn't taken. (The guard is
   skipped on a dry run.)
2. **`Signing secrets missing (CSC_LINK / APPLE_API_KEY_P8)`** (`build-mac`,
   "Guard: signing secrets present") — the secrets were removed or the run
   happened in a context that can't see them. Restore them (see the
   [setup checklist](./releasing.md#one-time-setup-checklist)) and re-run.
   The workflow refuses to publish unsigned on purpose — Squirrel.Mac would
   strand the installed base. (Skipped on a dry run.)
3. **`Azure signing configuration missing: <names>`** (`build-windows`,
   "Guard: Azure signing configuration present") — one or more of the four
   `AZURE_SIGN_*` identifiers or the three client credentials are absent.
   See [5](#5-windows-azure-artifact-signing). (Skipped on a dry run.)

The backend image is built, integration-tested, and pushed **inside CI** by
the `build-image` job (`bin/publish-image $VERSION --multi-arch
--skip-latest`) — there is no longer any "publish the image by hand before
tagging" step, and no "image not found on GHCR" guard. If `build-image`
fails, read its `bin/publish-image` / `bin/test-docker` output directly.

## 3. macOS signing

### 3.1 Wrong certificate type

- **Symptom (grep):** `The binary is not signed with a valid Developer ID
  certificate` — in the notarytool developer log, verdict `Invalid`.
  Signing itself succeeds, so this only surfaces after the full build +
  notarization round-trip.
- **Cause:** `CSC_LINK` holds an "Apple Development" / "Apple
  Distribution" / "Mac App Store" cert instead of **Developer ID
  Application**. Direct-distribution notarization accepts only the latter
  ([Apple forums](https://developer.apple.com/forums/thread/714156),
  [electron-builder #6094](https://github.com/electron-userland/electron-builder/issues/6094)).
- **Check:** electron-builder prints the identity it picked in its
  `signing` log line — it must start with `Developer ID Application:`. On
  an artifact: `codesign -dvv Syrus.app 2>&1 | grep Authority`. Locally,
  `bin/signing-env` warns about exactly this at build start
  (`syrus_signing_check_mac_cert_type`).
- **Fix:** Export the `Developer ID Application: <name> (<TEAMID>)` cert
  **with its private key** from Keychain Access as `.p12`, re-encode:
  `base64 -i cert.p12 | tr -d '\n'` → `CSC_LINK`. Only the account holder
  can create Developer ID certs.

### 3.2 Mangled CSC_LINK or wrong p12 password

- **Symptom (grep):** `Env CSC_LINK is not correct, cannot resolve` /
  `it doesn't look like a valid base64` — or —
  `MAC verification failed during PKCS12 import (wrong password?)`.
- **Cause:** the base64 was line-wrapped (`base64` wraps at 64/76 chars by
  default on Linux), lost its `=` padding in a copy-paste, or the password
  secret has a stray trailing newline. A `.p12` exported by OpenSSL 3 with
  modern ciphers can also defeat the runner's `security` tool
  ([#6921](https://github.com/electron-userland/electron-builder/issues/6921),
  [community discussion](https://github.com/orgs/community/discussions/179605)).
- **Check:** decode the secret value locally and interrogate it:
  `pbpaste | base64 -d > /tmp/cert.p12 && openssl pkcs12 -in /tmp/cert.p12 -noout -passin pass:<pw>`
  (add `-legacy` under OpenSSL 3 for Keychain exports). Compare
  `shasum -a 256` against your archived `.p12` — a mismatch means the
  secret got corrupted in transit, not the cert.
- **Fix:** regenerate as one line (`base64 -i cert.p12 | tr -d '\n'`), and
  re-enter `CSC_KEY_PASSWORD` avoiding `echo`-appended newlines. If
  OpenSSL opens the p12 but `security` refuses, re-export with
  `openssl pkcs12 -export -legacy` or from Keychain Access.

### 3.3 Keychain hangs on the runner

- **Symptom (grep):** `errSecInternalComponent`, or the job goes silent
  mid-signing (last line is a `signing file=...` invocation) until you
  cancel it. Reproduces only in CI — locally the keychain prompt is
  interactive.
- **Cause:** codesign is blocked on a keychain password prompt that a
  headless runner can never answer — locked keychain or the post-10.12.5
  key partition-list ACL
  ([Apple forums](https://developer.apple.com/forums/thread/666107),
  [2025 Electron writeup](https://www.codejam.info/2025/06/github-action-hanging-macos-app-code-signing.html)).
- **Check:** our workflow does *not* hand-roll a keychain — electron-builder
  manages a temporary one from `CSC_LINK`/`CSC_KEY_PASSWORD`, which
  normally sidesteps this entirely. If it hangs anyway, suspect a runner
  image change (job log header shows the image version).
- **Fix:** re-run first — this class is flaky. If it persists across a
  runner-image bump, the escape hatch is the classic six-command ephemeral
  keychain recipe ending in
  `security set-key-partition-list -S apple-tool:,apple: -s -k "$PW"`,
  but exhaust re-runs and image pinning before hand-rolling it.

## 4. macOS notarization

### 4.1 Invalid verdict: pull the developer log

- **Symptom (grep):** notarytool `status: Invalid` — usually with an empty
  `statusMessage` and nothing but "Processing complete". The reasons are
  **only** in the developer log, never in the summary
  ([notarytool man page](https://keith.github.io/xcode-man-pages/notarytool.1.html),
  [TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)).
- **Check:** you don't need runner access — the notary service is
  account-scoped, and the [local signing setup](./releasing.md#signing-locally)
  gives your machine the same App Store Connect key CI uses:

  ```bash
  source <(grep -E 'APPLE_API' ~/.config/syrus/mac-signing.env | sed 's/^/export /')
  xcrun notarytool history --key ~/.config/syrus/apple-api-key.p8 \
    --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER"
  xcrun notarytool log <submission-id> --key ~/.config/syrus/apple-api-key.p8 \
    --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" developer_log.json
  ```

  Read the `issues` array: each entry names the offending file and reason.
  (If you need the submission id from CI instead, re-run with
  `DEBUG=electron-notarize*` in the build step's env.)
- **Fix:** whatever the log says — see [4.2](#42-entitlements-and-hardened-runtime)
  for the usual suspects. **Never blind-retry an Invalid verdict**: it's
  deterministic and will fail identically until the code/config changes.
  (Contrast with [4.3](#43-hangs-and-timeouts), which is retry-first.)

### 4.2 Entitlements and hardened runtime

- **Symptom (grep, in the developer log JSON):**
  `The executable requests the com.apple.security.get-task-allow
  entitlement` / `does not have the hardened runtime enabled` /
  `The signature does not include a secure timestamp`.
- **Cause:** a debug entitlement leaked into the release, hardened runtime
  got disabled, or a new **nested binary shipped unsigned** — in this app
  that means anything new under `extraResources` (the staged Go CLI
  binaries in `resources/cli`, backend assets) or a native `.node` module
  outside the asar
  ([hardened runtime explainer](https://eclecticlight.co/2021/01/07/notarization-the-hardened-runtime/)).
- **Check:** map each issue path from the log to a file in the app. Then
  `codesign -d --entitlements :- Syrus.app` (look for `get-task-allow`)
  and `codesign -dvv` (expect `flags=0x10000(runtime)` and a `Timestamp=`
  line). Note `desktop/electron-builder.yml` already sets
  `hardenedRuntime: true` + `build/entitlements.mac.plist` — a regression
  here almost always came in with a new bundled binary.
- **Fix:** sign every listed path (electron-builder signs what it knows
  about — check nothing is excluded via `signIgnore`/asar config), keep
  `hardenedRuntime: true`, keep default timestamping.

### 4.3 Hangs and timeouts

- **Symptom:** the build step produces no output for 30–120+ minutes
  during the notarize phase; or a transient
  `Failed to notarize via notarytool ... unexpected result` that succeeds
  on plain re-run.
- **Cause:** Apple notary backlog — submissions sit "In Progress"
  server-side for hours during incidents
  ([electron/notarize #179](https://github.com/electron/notarize/issues/179),
  [Apple forums](https://developer.apple.com/forums/thread/736977),
  [tauri discussion](https://github.com/orgs/tauri-apps/discussions/8630)).
  There's no `timeout-minutes` on the job, so the GitHub default (6 h)
  is the only backstop — don't wait for it.
- **Check:** distinguish backlog from breakage from your own machine:
  `xcrun notarytool history ...` (creds as in [4.1](#41-invalid-verdict-pull-the-developer-log)).
  Submission exists and is `In Progress` → queue latency, your config is
  fine. `notarytool log` returning "Submission log is not yet available"
  confirms it (the log only exists after processing completes). Also check
  [Apple System Status](https://developer.apple.com/system-status/) →
  Developer ID Notary Service.
- **Fix:** cancel and re-run the job — the abandoned submission keeps
  processing server-side and costs nothing. Bounded retries are fine for
  this transport/queue class; they are *not* fine for `Invalid`
  ([electron/notarize #219](https://github.com/electron/notarize/issues/219)).

### 4.4 Stapler failures

- **Symptom (grep):** `The staple and validate action failed! Error 65` —
  either during the build or in our **"Verify signature, notarization, and
  update feed"** step (`xcrun stapler validate` on each `.app`). The staple
  runs against the `.app`, not the DMG container — Error 65 on a DMG is
  expected, not a failure.
- **Cause:** no ticket exists for that artifact's cdhash: notarization
  never completed / ended Invalid, the artifact was modified after
  notarization (cdhash changed), or the ticket hasn't propagated to
  Apple's CDN yet
  ([Apple forums](https://developer.apple.com/forums/thread/115670)).
- **Check:** `notarytool history` — was the submission `Accepted`? Compare
  the `.app`'s cdhash (`codesign -dvv`) against the cdhash list in the
  notary log.
- **Fix:** for CDN lag, retry `stapler validate` after 30–60 s. Otherwise
  fix the upstream notarization and re-run. Because `build-mac` uses
  `--publish never` and only STAGES its outputs, a red here uploads
  nothing — the GitHub Release stays untouched, so a re-run has no stale
  assets to collide with.

## 5. Windows (Azure Artifact Signing)

Windows signing runs live in `release.yml`'s `build-windows`
job on every manual dispatch (in parallel with `build-mac`); its guard
fails the run when any of the four `AZURE_SIGN_*` identifiers (or the
client credentials) are absent — add the listed ones per the
[secrets table](./windows-signing.md#6-repo-secrets).
`sign-windows-test.yml` exercises the same chain by manual dispatch
without cutting a release (the workflow file must be on the default
branch for the button to exist — the fork workaround is in
[windows-signing.md §7](./windows-signing.md#7-test-it)); its guard says
`Missing secrets/variables: <names>`. Note `azureSignOptions` is
injected via CLI dot-paths, never committed to `electron-builder.yml` —
its mere presence would force signing on every unsigned dev build.

### 5.1 Module install failures

- **Symptom (grep):** `Install-PackageProvider: No match was found for the
  specified search criteria for the provider 'NuGet'`, or
  `Install-Module` failures for `TrustedSigning` mid-build.
- **Cause:** electron-builder installs the TrustedSigning PowerShell
  module (and the NuGet provider) on the fly at first sign; PSGallery
  bootstrap on a fresh runner is flaky
  ([#8828](https://github.com/electron-userland/electron-builder/issues/8828),
  [walkthrough](https://hendrik-erz.de/post/code-signing-with-azure-trusted-signing-on-github-actions)).
- **Check:** the `Install-PackageProvider`/`Install-Module` lines appear in
  electron-builder's output right before the failure — i.e. nothing
  pre-installed the toolchain.
- **Fix:** re-run (often enough). Durable fix: a dedicated pwsh step
  before the build —
  `Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser;
  Install-Module TrustedSigning -RequiredVersion <pinned> -Force -Scope CurrentUser`
  — pinned, so it's neither a flake nor a supply-chain hole.

### 5.2 The concurrent-signing race

- **Symptom (grep):** `The process cannot access the file
  '...Azure.CodeSigning.Dlib.dll' because it is being used by another
  process` / `Package 'Microsoft.Trusted.Signing.Client' failed to be
  installed` / `SignTool failed with exit code 3`. Nondeterministic
  across runs.
- **Cause:** electron-builder signs multiple files in parallel (we build
  x64 + arm64 in one invocation — installers, uninstallers, helpers), and
  each parallel `Invoke-TrustedSigning` call races to install the same
  NuGet packages
  ([#8615](https://github.com/electron-userland/electron-builder/issues/8615),
  recurrence on 26.0.13:
  [#9076](https://github.com/electron-userland/electron-builder/issues/9076)).
- **Check:** file-lock errors naming `Microsoft.Trusted.Signing.Client` or
  `Microsoft.Windows.SDK.BuildTools` paths = the race, not credentials.
  Worst on a fresh runner with no cached module.
- **Fix:** pre-install the module before the build (see 5.1) so no install
  happens during signing; keep electron-builder current (the
  serialization fix landed via #8632 but treat it as incomplete); last
  resort, a custom sequential `win.sign` hook.

### 5.3 403 Forbidden

- **Symptom (grep):** `Status: 403 (Forbidden)` from
  `codesigning.azure.net`, often wrapped in `SignerSign() failed` /
  `0x80004005`. (`AADSTS` errors are different — that's authentication:
  wrong tenant/client/secret, or the app registration was created with
  the wrong account type — see
  [windows-signing.md §5](./windows-signing.md#5-service-principal-for-ci-no-interactive-login-in-actions).)
- **Cause:** authorization, not authentication. In rough order of
  likelihood: the role went to your *user* instead of the service
  principal (the workflow authenticates as the app registration, not as
  you); identity validation not `Completed` (or expired —
  [5.5](#55-identity-validation-expiry)); account/profile/endpoint values
  wrong
  ([MS Q&A](https://learn.microsoft.com/en-us/answers/questions/5633617/403-forbidden-error-when-using-signtool-with-trust),
  [melatonin.dev guide](https://melatonin.dev/blog/code-signing-on-windows-with-azure-trusted-signing/)).
- **Check:** portal → Trusted Signing account → **Access control (IAM)**:
  the app registration (e.g. `syrus-release-ci`) must hold **"Trusted
  Signing Certificate Profile Signer"**. Then Identity validation status.
  Then compare `AZURE_SIGN_ENDPOINT` (region-coded, e.g.
  `https://eus.codesigning.azure.net`), `AZURE_SIGN_ACCOUNT_NAME`, and
  `AZURE_SIGN_CERT_PROFILE` character-for-character against the portal.
  The workflow already strips a trailing slash from the endpoint.
- **Fix:** assign the role to the exact SP used by CI (propagation takes a
  few minutes), complete/renew the validation, or fix the mismatched
  name. Microsoft's own guidance adds: transient 403/500s exist —
  [retry before re-architecting](https://learn.microsoft.com/en-us/answers/questions/2280136/signtool-fails-with-opaque-error-(trusted-signing)).

### 5.4 publisherName and CN mismatches

- **Symptom:** signing fails against the profile, or (later, in the field)
  electron-updater refuses a downloaded update with a
  `publisherNames ... doesn't match` class error; our verify step throws
  `<exe> is not validly signed (status: ...)`.
- **Cause:** `AZURE_SIGN_PUBLISHER_NAME` must match the certificate
  profile's Subject CN **byte-for-byte** (it's threaded into
  `win.azureSignOptions.publisherName`). Trusted Signing certs often
  render the legal name differently (e.g. uppercase) than expected, and
  electron-updater validates installers against the configured publisher
  ([#8696](https://github.com/electron-userland/electron-builder/issues/8696)).
- **Check:** on a signed artifact:
  `Get-AuthenticodeSignature .\Syrus-Setup-*.exe | % { $_.SignerCertificate.Subject }`
  and compare with the secret and the certificate profile page.
- **Fix:** set the secret to the exact CN. If the CN ever changes (cert
  migration), ship an interim release that lists both old and new names
  so existing installs accept the newly-signed update before the old
  entry is dropped.

### 5.5 Identity validation expiry

- **Symptom:** signing worked for months, now every run 403s with zero
  config changes. The portal shows the identity validation expired;
  "Action required" renewal emails were missed.
- **Cause:** Azure identity validation **expires every 2 years**
  ([windows-signing.md §3](./windows-signing.md#3-identity-validation) told
  you to set a calendar reminder — this is why). Once lapsed, cert
  issuance stops and every sign call against profiles tied to it fails.
- **Check:** portal → Trusted Signing account → Identity validations →
  status/expiry. Correlate the first red run with the expiry date.
- **Fix:** renewal is only possible starting **60 days before expiry**.
  After expiry you must create a *new* identity validation (ID + selfie
  again), then recreate the certificate profile **with the same name**
  pointing at the new validation so no CI secret changes
  ([MS renewal doc](https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-renew-identity-validation)).

### 5.6 Timestamping

- **Symptom (grep):** intermittent `SignerSign() failed` / errors naming
  `timestamp.acs.microsoft.com`; or signed builds whose signature dies
  later because **no timestamp was applied**.
- **Cause:** the Microsoft ACS timestamp endpoint fails intermittently
  under batch signing
  ([Rick Strahl's writeup](https://weblog.west-wind.com/posts/2026/Feb/26/Dont-use-the-Microsoft-Timestamp-Server-for-Signing)),
  and electron-builder's Azure path once shipped without RFC3161 params
  entirely ([#8626](https://github.com/electron-userland/electron-builder/issues/8626)).
  This matters more than on other platforms: Trusted Signing certs are
  short-lived, so an untimestamped signature expires with the cert —
  within days.
- **Check:** post-sign,
  `Get-AuthenticodeSignature .\Syrus-Setup-*.exe | % { $_.TimeStamperCertificate }`
  must be non-null (our verify step checks `Status -eq Valid` but not the
  timestamp — check it by hand when suspicious). Flakiness across re-runs
  with identical config = TSA availability, not you.
- **Fix:** re-run; keep electron-builder past the no-timestamp bug; if
  driving signtool by hand, use RFC3161 (`/tr http://... /td SHA256`,
  plain http — https TSAs are unsupported).

## 6. electron-builder generalities

### 6.1 Green build, unsigned artifact

- **Symptom (grep):** `skipped macOS application code signing` or
  `skipped macOS notarization` — the build **succeeds** and ships a
  Gatekeeper-blocked app. This is electron-builder's default behavior for
  missing/invalid signing config
  ([#4295](https://github.com/electron-userland/electron-builder/issues/4295)).
- **Cause:** no resolvable identity (wrong cert type also lands here), an
  empty env var, or `CSC_IDENTITY_AUTO_DISCOVERY=false` anywhere in the
  env — which disables signing *even when `CSC_LINK` is set*
  ([#7515](https://github.com/electron-userland/electron-builder/issues/7515)).
  In our workflow that variable is intentionally set **only** on the
  "Build unsigned (dry run)" step (the `dry_run == 'true'` path); if it ever
  migrates to job-level env, real (non-dry) releases silently unsign.
- **Check:** grep every release log for `skipped` — cheap and decisive.
  The workflow's defenses are the "Guard: signing secrets present" step
  (catches *absent* secrets, not invalid ones) and the post-build verify
  step (`codesign --verify --deep --strict` + `Developer ID Application`
  grep + `stapler validate`), which is the real backstop.
- **Fix:** address whichever section above the skip reason points at.
  Note `forceCodeSigning: true` (which turns skips into hard failures,
  per [electron-builder docs](https://www.electron.build/configuration))
  is deliberately *not* in `desktop/electron-builder.yml` — it would break
  unsigned local dev builds. If adding it, inject via CLI override in the
  release workflow only.

### 6.2 Publish-job failures

The `publish` job is the single atomic commit point — it runs only after
every build job succeeded, and it does three things in sequence: create the
release with all staged assets, move the image `:latest` pointer, and commit
the version bump to main. Each has its own failure signature.

- **`no staged artifacts to publish`** ("Create the GitHub release" step) —
  `publish` downloads the `staged-*` upload-artifacts, `find`s every file,
  and aborts if the set is empty. This means a build job went green but
  produced nothing to stage (its `upload-artifact` steps use
  `if-no-files-found: error`, so an empty stage normally reds the build job
  first — reaching this error implies the artifacts expired or the download
  matched nothing). **Check:** open each build job's "Stage …" step and its
  `upload-artifact` step; confirm `staged-cli` / `staged-mac` /
  `staged-windows` exist under the run's artifacts and haven't passed their
  7-day retention. **Fix:** re-dispatch the whole pipeline — the builds are
  cheap relative to a broken release, and nothing was published.

- **`imagetools create` fails moving `:latest`** ("Move image :latest to the
  released version" step) — `docker buildx imagetools create -t
  ghcr.io/tkadauke/syrus-local:latest ...:$VERSION` copies the already-pushed
  multi-arch manifest onto `:latest`. A failure here is auth/permissions on
  GHCR, not a build problem: the versioned image already exists (build-image
  pushed it). **Note the GitHub Release is already live at this point** — the
  create-release step ran first. **Check:** the "Log in to GHCR" step
  succeeded (it uses `github.actor` + `GITHUB_TOKEN`); the top-level
  `permissions:` still grants `packages: write`; the `syrus-local` package
  isn't locked to a different owner. **Fix:** restore the packages-write
  grant / GHCR permission and re-run just this move by hand:
  `docker buildx imagetools create -t ghcr.io/tkadauke/syrus-local:latest
  ghcr.io/tkadauke/syrus-local:X.Y.Z`. The release does not need re-cutting.

- **`Could not push the version bump to <branch>`** ("Commit the version bump
  to main" step) — this is a **`::warning`, not a failure**: the step catches
  a rejected push (branch protection on `main`) and continues green. The
  release is already published and the tag carries the version forward; only
  `desktop/package.json` on `main` is stale. **Fix:** bump
  `desktop/package.json`/`package-lock.json` to `X.Y.Z` in a normal PR (or
  let the next release self-correct — `prepare` bases the next version on the
  higher of the latest tag and package.json, so the tag already floors it).

### 6.3 Update feed integrity

- **Symptom (grep, in client logs):** `Cannot find latest-mac.yml in the
  latest release artifacts` (HttpError 404), blockmap 404s /
  `Cannot parse blockmap`, or sha512 checksum mismatches — a published
  release that breaks auto-update in the field.
- **Cause:** the release is missing part of its atomic asset set, or an
  asset was renamed/re-uploaded by hand after the ymls were generated —
  `latest-mac.yml` embeds exact file names, sizes, and sha512 hashes
  ([#4942](https://github.com/electron-userland/electron-builder/issues/4942),
  [#3936](https://github.com/electron-userland/electron-builder/issues/3936)).
  The mac `zip` targets are load-bearing: dmg-only builds can't produce
  `latest-mac.yml` at all, and Squirrel.Mac installs from the zip
  ([#2137](https://github.com/electron-userland/electron-builder/issues/2137)) —
  the comment in `desktop/electron-builder.yml` saying zip is REQUIRED
  is not decorative.
- **Check:** `gh release view vX.Y.Z` and confirm the full set: both DMGs,
  both zips, `latest-mac.yml` (mac feed), `Syrus-Setup-*.exe` + `latest.yml`
  (Windows feed), and every `*.blockmap`. The build jobs verify these are
  present before staging (`grep -q "Syrus-$VERSION-arm64.zip"
  latest-mac.yml`, `Test-Path desktop/out/latest.yml`), and `publish`
  uploads whatever was staged in one `gh release create`. The stable-named
  `Syrus.dmg` / `Syrus-Intel.dmg` / `Syrus-Setup.exe` aliases are *outside*
  the feed (website permalinks only) — clobbering those is always safe.
- **Fix:** re-dispatch the pipeline so the feed is regenerated and uploaded
  as a matched set. Never hand-edit, rename, or re-upload a published asset —
  every client hash check fails against a modified file. If the ymls and
  binaries have diverged beyond repair, ship a patch release; that's cheaper
  than un-breaking a poisoned feed.

## 7. Reproduce locally to bisect

The single most useful move on a confusing red run: take CI out of the
equation. Per [releasing.md](./releasing.md#signing-locally),
`bin/release-desktop` (via `bin/signing-env`) reads the same credential
names from `~/.config/syrus/mac-signing.env` +
`~/.config/syrus/apple-api-key.p8` and runs the identical electron-builder
path — signing and notarizing for real, no tag or CI minutes spent.

```bash
bin/release-desktop v0.0.0-debug --skip-tests
```

Then bisect:

| Local | CI | Conclusion |
| --- | --- | --- |
| red | red | credential/config problem (cert type, expired cert, entitlements, bad key) — fix the credential, sections 3–4 |
| green | red | CI-side: secret got mangled in transit (compare decoded-p12 `shasum` local vs. a temporary debug step), runner image changed (job log header), or Apple was backed up at that hour |
| was green, red now, no diff | — | external: [Apple System Status](https://developer.apple.com/system-status/), Azure identity expiry ([5.5](#55-identity-validation-expiry)), runner image migration, GHCR availability |

Battle scars for the local leg:

1. **Run from a clean, non-Dropbox clone.** Cloud-synced xattrs break
   codesign nondeterministically (already warned in releasing.md — it's
   real, and this repo's primary checkout lives in Dropbox).
2. `bin/signing-env` prints a wrong-cert-type warning at build start and a
   mode warning if the env files aren't `chmod 600` — read its output
   before blaming CI.
3. **Windows cannot be bisected locally from a Mac.** `Invoke-TrustedSigning`
   is Windows-only; the windows loader in `bin/signing-env` deliberately
   no-ops on Darwin ([windows-signing.md §8](./windows-signing.md#8-local-signing-and-why-it-doesnt-work-from-this-mac)).
   The bisect tool there is `sign-windows-test.yml` via manual dispatch —
   from a fork while the workflow isn't on the default branch.
4. The notary service is account-scoped, not machine-scoped: your local
   `notarytool history` / `log` sees CI's submissions too
   ([4.1](#41-invalid-verdict-pull-the-developer-log)). That's usually
   faster than adding debug steps to the workflow.
