# Syrus for iOS

Native iOS shell for Syrus: a SwiftUI app that lets an operator pick a Syrus
server, loads the Syrus web UI in a `WKWebView`, and receives APNs push
notifications. Everything lives under `ios/`.

## Layout

| Path | Purpose |
| --- | --- |
| `project.yml` | XcodeGen spec (source of truth; `Syrus.xcodeproj` is generated and git-ignored) |
| `Syrus/Servers` | `ServerURL` parsing, persisted `ServerStore`, connection screen |
| `Syrus/Web` | `WKWebView` host, `NavigationPolicy`, load/error states |
| `Syrus/Push` | APNs authorization, token registration with the Syrus API, notification routing |
| `SyrusTests` | Unit tests (URL parsing, persistence, navigation policy, push registration) |

## Local setup

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd ios
make generate   # create Syrus.xcodeproj
make open       # open in Xcode
make build      # simulator build, unsigned
make test       # unit tests on the simulator (override with SIMULATOR='platform=iOS Simulator,name=iPhone 16')
```

## Simulator and server configuration

On first launch the app shows the connection screen. Enter an address such as
`syrus.example.com` (defaults to `https`) or `localhost:3000` (local hosts
default to `http`; Debug builds prefill `http://localhost:3000`). The server
origin and up to five recent servers are stored in `UserDefaults`. Session
cookies live in the web view's persistent data store.

To skip the screen in development or UI automation, pass a launch argument
(also settable in the Xcode scheme): `-SyrusServerURL http://localhost:3000`.
Use **⋯ → Switch server** to return to the connection screen; this unregisters
the device's push token from the old server and clears that server's web data.

Navigation: same-origin pages stay in the app; tapped cross-origin links open
in Safari; cross-origin redirects (e.g. sign-in via GitHub) stay in-app. The
Info.plist allows plain HTTP for web content only; native code makes no
network requests itself.

## Push notifications

Flow: the app asks for notification permission (⋯ → *Enable notifications*),
registers with APNs, and hands the hex device token to Syrus **through the
signed-in web view** (it reuses the session cookie and CSRF token, so the app
stores no credentials):

- `POST /api/v1/app/mobile_devices` — `token`, `bundle_id`, `apns_environment`
  (`sandbox` for Debug, `production` for Release), `device_name`, `app_version`, `os_version`.
  Tokens are tied to the user and session; signing out deletes them, and a
  token re-registered by another user moves to that user.
- `DELETE /api/v1/app/mobile_devices/unregister` — `token`.

Whenever Syrus creates an in-app `Notification` for a user with registered
devices, `MobilePushDeliveryJob` sends it via APNs (token auth, HTTP/2) with
the unread count as badge and `syrus.target_path` for deep linking on tap.
Devices APNs reports as invalid (`410`, `BadDeviceToken`, `Unregistered`) are disabled.

### Prerequisites (cannot be exercised in CI or on the simulator)

1. Apple Developer Program membership and an App ID with the **Push
   Notifications** capability for the bundle id (`app.syrus.ios` by default;
   override the bundle id and set your team as described in *Signing and TestFlight*).
2. An APNs auth key (`.p8`) from *Certificates, Identifiers & Profiles → Keys*.
3. Configure the Syrus server environment:
   `SYRUS_APNS_TEAM_ID`, `SYRUS_APNS_KEY_ID`, and either `SYRUS_APNS_AUTH_KEY`
   (PEM, `\n` escapes allowed) or `SYRUS_APNS_AUTH_KEY_PATH`; optionally
   `SYRUS_APNS_TOPIC`. Without these, delivery is skipped silently.
4. A physical device: the simulator never receives a real APNs token. Debug
   builds use the sandbox endpoint; Release/TestFlight builds use production.

Covered locally: Swift unit tests for registration logic and routing, and Rails
specs for the device API, APNs client (fake transport) and delivery job.
Not covered: real delivery to Apple.

## Signing and TestFlight

No signing material is committed. The bundle id defaults to `app.syrus.ios`;
the team, bundle-id override, and API key come from your environment.

- `Config/Shared.xcconfig` holds defaults; copy `Config/Local.xcconfig.example`
  to the git-ignored `Config/Local.xcconfig` to set `DEVELOPMENT_TEAM` for
  Xcode device builds.
- Debug uses `Syrus.Debug.entitlements` (`aps-environment: development`);
  Release uses `Syrus.Release.entitlements` (`production`). Both are
  automatically signed. Simulator builds/tests stay unsigned (`make test`).
- `PrivacyInfo.xcprivacy` declares no tracking, the push token as app-functionality
  device ID, and `UserDefaults` access (reason `CA92.1`);
  `ITSAppUsesNonExemptEncryption` is `false`. Review these before submitting if
  you add SDKs or data collection.
- The 1024px `AppIcon.png` is required by App Store Connect and must have no
  alpha channel; the launch screen uses the `LaunchBackground` color set.

Create an App Store Connect API key (.p8) with App Manager access, then:

```sh
export SYRUS_IOS_TEAM_ID=ABCDE12345
export ASC_KEY_PATH=$HOME/.appstoreconnect/AuthKey_XXXX.p8
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
# optional: SYRUS_IOS_BUNDLE_ID, SYRUS_IOS_BUILD_NUMBER (default: git commit count)
make archive   # build/release/Syrus.xcarchive (Release, generic iOS device)
make export    # signed .ipa in build/release/export (from ExportOptions.plist.template)
make upload    # export with destination=upload: sends the build to TestFlight
```

Without the ASC variables, `archive`/`export` use the signing identities and
profiles in your login keychain/Xcode account. Each upload needs a unique
build number (see *Versioning*). `make upload` requires the app record to exist in App Store Connect.

## Versioning

`MARKETING_VERSION` lives only in `project.yml`; bump it there for a new
user-visible release. The build number (`CFBundleVersion`) is derived by
`scripts/version.sh build`: `SYRUS_IOS_BUILD_NUMBER` if set, otherwise the
commit count of `HEAD`, so every checkout of the same commit yields the same
number and numbers rise along `main`. Shallow clones are rejected; use full
history. `scripts/version.sh full` prints `0.1.0 (123)`.

## CI and release automation

- **iOS CI** (`.github/workflows/ios-ci.yml`) runs on PRs and `main` pushes
  touching `ios/**`: macOS runner, `xcodegen generate`, simulator build and
  unit tests (`make test`), unsigned. The test log is kept as an artifact for
  14 days. Syrus also runs the `xcode-test` grader on macOS workers.
- **iOS Release** (`.github/workflows/ios-release.yml`) is
  `workflow_dispatch` only. Choose `archive`, `export`, or `upload`, and
  optionally a build number. It runs in the `ios-release` GitHub environment
  (add required reviewers there). Configure secrets `SYRUS_IOS_TEAM_ID`,
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the .p8 contents) and optional
  variable `SYRUS_IOS_BUNDLE_ID`. The key is written to a temp file, deleted
  afterwards, and never printed. Logs plus `metadata.txt` (version, build,
  commit) are kept 30 days; the archive/ipa 14 days.

### Failure recovery

- Build fails before upload: fix and re-run; nothing was published.
- Upload rejected for a duplicate build number: re-run with a higher
  `build_number`.
- Signing/provisioning errors: read `build/release/logs/*.log` from the
  artifact; usually the App ID lacks Push Notifications or the key lacks
  App Manager access.
- Local fallback: the same `make archive|export|upload` with the environment
  variables above.

### Rollback

A build uploaded to TestFlight cannot be deleted by this pipeline. To roll
back, expire the bad build in App Store Connect and have testers reinstall the
previous build, or re-release the last good commit with a new, higher build
number (build numbers must never be reused). Server-side push changes are
independent of the app build.

## Diagnostics and physical-device acceptance

**⋯ → Diagnostics** shows each push-setup step with a pass/warn/fail marker:
selected server, session state, notification permission, APNs token (last six
characters only), APNs environment and bundle id, token sync outcome, what the
server has registered for you (including "APNs not configured", "device
disabled: …" and sandbox/production mismatch), app version/build, and the last
push and deep-link events. No secret or full token is ever displayed. **Send test
notification** calls `POST /api/v1/app/mobile_devices/test_notification`, which
pushes only to your own registered device(s) and deep-links to `/notifications`.

Run this checklist on a physical device once for the **sandbox** (Xcode Debug
build) and once for **production** (TestFlight/Release build). The simulator
cannot do it.

1. Install the build; connect to the server and sign in.
2. ⋯ → *Enable notifications* and allow. Open ⋯ → *Diagnostics*, tap *Refresh*.
3. Every row is green: Session *Signed in*, Permission *Authorized*, APNs token
   present, Token sync *Registered with server*, Server push status *Registered
   (sandbox|production)* matching the build. If a row is red, it names the failing
   step (permission denied, no token → check the Push Notifications capability
   and signing; *APNs is not configured* → server `SYRUS_APNS_*`; environment
   mismatch → wrong build type for the key's environment).
4. Tap *Send test notification*; expect “Sent”. A *token rejected* message means
   APNs refused the token (BadDeviceToken/DeviceTokenNotForTopic → environment or
   bundle id mismatch).
5. With the app **in the foreground**, the banner appears; *Last push* shows
   `test (foreground)`.
6. Send again, background the app, tap the notification: the app opens the
   Notifications page; *Last push* shows `test (tapped)` and *Last deep link*
   shows `opened /notifications`. Repeat from a force-quit state.
7. Sign out in the web UI (or ⋯ → *Switch server*): Diagnostics/the server no
   longer lists the device, and a test push sends nothing to it.
8. Switch to a second server, sign in, and confirm the device registers there and
   not on the first.


## Shell failure states

The web shell attributes every load failure to a source so testers can tell
where to look (`Syrus/Web/WebFailure.swift`):

| Source | Examples | Recovery |
| --- | --- | --- |
| Network problem | offline, timeout, DNS/host unreachable | auto-retries when connectivity returns or the app foregrounds; **Try again** |
| Server problem | HTTP 5xx, untrusted certificate, TLS failure, dropped connection | **Try again** (hidden for certificate errors), **Change server** |
| Session expired | main-frame HTTP 401/403 | **Sign in again** restarts at the server root |
| App problem | web content process killed repeatedly | **Try again** |

Other shell behaviors: a banner shows while offline with a page loaded;
attachments and non-renderable responses download and open the share sheet;
pull-to-refresh keeps its spinner until the reload finishes; the keyboard
shrinks the web view; errors are announced to VoiceOver and the error screen
scales with Dynamic Type.
