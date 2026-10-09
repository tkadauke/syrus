# ios

`ios` is a Syrus plugin gem for iOS and Swift validation that must run on
native macOS workers. It lives at `plugins/ios/` and contributes typed grader
declarations rather than scheduler special cases.

## What it provides

| Extension point | What it does |
|---|---|
| `:prepare_detector` | Detects root `Package.swift`, Xcode workspaces/projects, and Swift source layouts. It contributes `swift package resolve` only for root Swift packages; Xcode dependency resolution remains explicit because it needs the repository's workspace/project and scheme choice. |
| `:grader_type` | Expands `type: xcodebuild` and `type: swiftpm` entries into shell-backed grader steps with macOS/Xcode capability metadata, isolated DerivedData or SwiftPM build paths, timeout defaults, and structured artifact metadata. |

## Typed grader examples

Xcode simulator tests:

```yaml
grade:
  - type: xcodebuild
    workspace: MobileApp.xcworkspace
    scheme: MobileApp
    destination: "platform=iOS Simulator,name=iPhone 16,OS=latest"
    derived_data_path: .syrus/DerivedData/mobile
    result_bundle_path: build/syrus/MobileApp.xcresult
    junit_output: build/syrus/junit/mobile.xml
    timeout_minutes: 45
```

Swift Package Manager tests:

```yaml
prepare:
  - swift package resolve

grade:
  - type: swiftpm
    package_path: Packages/Shared
    build_path: .syrus/DerivedData/shared
    timeout_minutes: 20
```

Both grader types default to:

```yaml
capabilities:
  os: macos
  arch: arm64
  toolchain: xcode
  runtime: ios_simulator
```

Override `capabilities:` only when the target truly runs on a different worker
class, such as a pure Swift package that is intentionally validated on Linux.

## Loading the plugin

The plugin registers itself via a Rails engine `to_prepare` hook once
`gem "ios", path: "plugins/ios"` is bundled.

## Running tests

From the repo root:

```sh
bin/rspec plugins/ios/spec
```
