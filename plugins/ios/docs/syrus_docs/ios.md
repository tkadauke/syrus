# iOS plugin

The `ios` plugin (`plugins/ios/`) defines typed grader patterns for iOS and
Swift work that runs on native macOS workers. It does not add iOS-specific
routing branches. Each generated grader is an ordinary `.syrus.yml` grader
with execution `capabilities`, timeout metadata, and artifact metadata, so the
same worker-placement model can serve other platform toolchains later.

## Xcode simulator tests

Use `type: xcodebuild` for common `xcodebuild test` or build validation. The
grader requires exactly one of `workspace:` or `project:`, requires `scheme:`,
defaults the simulator destination to `platform=iOS Simulator,name=iPhone
16,OS=latest`, and writes isolated build products under the workspace:

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

The command removes the configured result bundle before running because
`xcodebuild` refuses to overwrite an existing `.xcresult`. It passes
`CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO` for ordinary simulator
tests. If a repository needs signing, keep Keychain/provisioning setup in the
macOS worker runbook and repository-owned scripts; do not put secrets in
`.syrus.yml`.

## Swift Package Manager

Use `type: swiftpm` for Swift Package Manager validation on the same macOS
worker pool:

```yaml
prepare:
  - swift package resolve

grade:
  - type: swiftpm
    package_path: Packages/Shared
    build_path: .syrus/DerivedData/shared
    action: test
    timeout_minutes: 20
```

Set `action: build` when the target should compile only. `build_path` is
isolated per run by default, matching the Xcode DerivedData isolation pattern.

For a repository-root `Package.swift`, the plugin's prepare detector can
auto-detect `swift package resolve`. Xcode dependency resolution should stay
explicit because `xcodebuild -resolvePackageDependencies` needs the same
workspace/project and scheme choices as the grader.

## Capabilities and artifacts

Both grader types default to:

```yaml
capabilities:
  os: macos
  arch: arm64
  toolchain: xcode
  runtime: ios_simulator
```

The generated metadata records the `.xcresult` bundle and DerivedData/SwiftPM
build directory as artifacts. If the command or wrapper emits JUnit XML, set
`junit_output:` so normal test-result ingestion and target health signals can
consume structured results. Leave it unset when the command only emits
`xcodebuild` logs and an `.xcresult` bundle.
