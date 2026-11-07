# iOS compute readiness

Declare iOS project requirements in the owning `.syrus.yml` and give Xcode
graders the same capability requirements:

```yaml
project:
  capabilities:
    os: macos
    arch: arm64
    toolchain:
      xcode: ">= 16.0"
    runtime:
      ios_simulator: "18.0"

grade:
  - name: ios-tests
    command: xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 16'
```

When filing direct work, provide the mutable implementation-workspace
placement explicitly, for example:

```json
{"planned_execution":{"os":"macos"}}
```

Mutable primary-workspace placement is OS-only and is separate from immutable
grader target capabilities such as architecture, Xcode, and simulator runtime.
Syrus never infers placement from proposal prose. If implementation discovers
that the declared placement is inadequate, the workflow records an
`implementation_capability_escalation` warning for operator review rather than
silently changing it.

`no_capable_worker` means no live worker currently satisfies the applicable
placement or target contract. Compare the requirement shown on the blocked Run
with live worker capabilities and distinguish a missing/misconfigured worker
from a requirement no pool is intended to satisfy.

Mac installation, launchd configuration, environment files, drain-aware
updates, and pool topology live in the [iOS/macOS worker
runbook](../../docs/engineering/operations/ios-compute.md).
