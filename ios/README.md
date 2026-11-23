# Syrus for iOS

A native iOS shell for Syrus. It lets an operator pick a Syrus server, loads
the Syrus web app in a `WKWebView`, and registers the device for APNs push
notifications. Everything for the app lives under `ios/`.

## Layout

| Path | Purpose |
|---|---|
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; source of truth for the Xcode project |
| `Syrus.xcodeproj` | Generated project, committed so Xcode/CI build without XcodeGen |
| `Syrus/Server` | `ServerURL` parsing, persistent `ServerStore`, connection screen |
| `Syrus/Web` | `WebController` (WKWebView boundary), `NavigationPolicy`, load/error state |
| `Syrus/Push` | `PushCoordinator`, registration scripts, payload parsing |
| `SyrusTests` | Unit tests (no network, no Apple credentials) |
| `docs/` | Setup, server configuration, push notifications |

After adding or removing source files, run `xcodegen generate` in `ios/` and
commit the regenerated project.

## Quick start

Requires Xcode 16+ (iOS 17 deployment target). Open `Syrus.xcodeproj`, pick an
iPhone simulator, and Run. Or from the terminal:

```sh
cd ios
xcodebuild test -project Syrus.xcodeproj -scheme Syrus \
  -destination "platform=iOS Simulator,name=iPhone 17" CODE_SIGNING_ALLOWED=NO
```

See [docs/setup.md](docs/setup.md), [docs/server-configuration.md](docs/server-configuration.md)
and [docs/push-notifications.md](docs/push-notifications.md).
