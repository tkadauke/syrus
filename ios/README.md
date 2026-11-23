# Syrus for iOS

A native SwiftUI shell around the Syrus web app: a server picker, a persistent
`WKWebView`, and APNs push notifications. Everything lives under `ios/`.

## Layout

| Path | Purpose |
| --- | --- |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec. `Syrus.xcodeproj` is generated and git-ignored. |
| `Syrus/Server` | `ServerURL` parsing/normalisation and `ServerStore` (UserDefaults persistence, recents). |
| `Syrus/Web` | `WebViewModel` (WKWebView, loading/error state, server switching) and `NavigationPolicy` (what stays in-app vs. opens in Safari). |
| `Syrus/Push` | `PushManager` (permission, token capture, registration) and `PushRegistration` (API contract). |
| `Syrus/Views` | Server selection, web shell, connection-error screen. |
| `SyrusTests` | Unit tests (no UI/network required). |

## Local setup

Requirements: macOS, Xcode 16+, `brew install xcodegen`.

```sh
cd ios
xcodegen generate
open Syrus.xcodeproj
```

Or from the command line (generates the project, builds, runs unit tests on a simulator):

```sh
ios/bin/build                                   # default: iPhone 17 simulator
SYRUS_IOS_DESTINATION="platform=iOS Simulator,name=iPhone 16" ios/bin/build
```

## Pointing the app at a server

On first launch the app shows **Connect to Syrus**. Enter a hostname or URL:

- `syrus.example.com` → `https://syrus.example.com`
- `localhost:3000`, `192.168.x.x:3000`, `*.local` → `http://…` (plain HTTP is only
  permitted for local networking by App Transport Security).

The choice is persisted (last five servers are kept as recents). Debug builds
suggest `http://localhost:3000`, which reaches `bin/dev` on the host Mac from the
simulator. Use **Change Server** on the error screen to switch; the device is
unregistered from the old server first.

## Push notifications

How it works:

1. After a Syrus page loads, the app asks for notification permission and
   registers with APNs.
2. The device token is sent to `POST /api/v1/app/push_devices` **from inside the
   web view**, so the request carries the signed-in session cookie and CSRF
   token; the app never stores credentials. A 401 (not signed in yet) is retried
   after the next page load; successful registrations refresh daily.
3. The server stores one `push_devices` row per token, bound to the user and
   session. Signing out destroys the session, which removes the device.
   `DELETE /api/v1/app/push_devices` removes it explicitly.
4. When a `Notification` is created, `NotificationPushJob` pushes it to the
   user's active devices. Tokens APNs reports as `Unregistered`/`BadDeviceToken`
   are disabled. Tapping a push opens its `target_path` (or `/notifications`).

### Prerequisites (cannot be exercised in CI)

- A paid Apple Developer account; set `DEVELOPMENT_TEAM` in `project.yml`.
- The bundle ID `estate.syrus.app` (change it in `project.yml` and set
  `APNS_BUNDLE_ID` on the server to match) with the Push Notifications capability.
- An APNs auth key (`.p8`). On the Syrus server set:
  `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_PRIVATE_KEY` (PEM contents) or
  `APNS_PRIVATE_KEY_PATH`; optionally `APNS_BUNDLE_ID`. Without them pushes are
  silently skipped.
- Push does not work in the Simulator on a real APNs path; use a physical device.
  Debug builds register as `sandbox`, release builds as `production`
  (match `aps-environment` in the entitlements).
- The server worker needs `curl` with HTTP/2 (APNs requires it).

Automated coverage: Swift unit tests cover URL parsing, persistence, navigation
policy and the registration contract; RSpec covers the registration API, device
lifecycle, the APNs client (JWT, host selection, error classification) and
delivery. The real APNs round trip needs the credentials above.
