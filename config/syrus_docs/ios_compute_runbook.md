# iOS compute readiness

Declare iOS project requirements in the owning `.syrus.yml` and give Xcode
graders the same capability requirements. Only `os` is an admission dimension
for the mutable implementation workspace; `arch`, `toolchain`, and `runtime`
describe the toolchain and simulator the project's commands and dependencies
need (preparation and grader targets), not where planned execution is placed:

```yaml
project:
  capabilities:
    os: macos            # the only placement/admission dimension
    arch: arm64          # preparation, commands, dependencies
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

## Tools on macOS workers

Besides Xcode and its simulators, every macOS worker puts these on the `PATH`
that prepare commands, agents, and graders run with: Ruby, Node and npm, mise,
the Claude Code and Codex CLIs, and XcodeGen. Projects that generate their
`.xcodeproj` from a `project.yml` can therefore generate it in `prepare`
before anything builds:

```yaml
prepare:
  - xcodegen generate
```

The versions are pinned by Syrus and updated with each deploy; a project does
not need to install them, and should not install them with Homebrew.

Mac worker installation, environment files, updates, and troubleshooting
live behind the [macOS workers
hub](../../docs/engineering/operations/macos-workers.md); iOS Jobs and
placement are in the [iOS compute
runbook](../../docs/engineering/operations/ios-compute.md).
