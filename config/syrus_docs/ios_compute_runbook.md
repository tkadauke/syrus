# iOS compute readiness

Declare iOS project requirements in the owning `.syrus.yml` and give Xcode
graders the same OS requirement. `os` is the only capability dimension Syrus
validates and uses to admit workers, for both the mutable implementation
workspace and grader targets. Architecture, Xcode version, and simulator
runtime are not capability keys; express them through the project's
preparation, commands, and dependencies instead.

```yaml
project:
  capabilities:
    os: macos            # the only placement/admission dimension

grade:
  - name: ios-tests
    command: xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 16'
    capabilities:
      os: macos
```

When filing direct work, provide the mutable implementation-workspace
placement explicitly, for example:

```json
{"planned_execution":{"os":"macos"}}
```

Mutable primary-workspace placement is OS-only and is separate from immutable
grader target capabilities. Architecture, Xcode, and simulator runtime are
handled by preparation and commands, not admission.
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
