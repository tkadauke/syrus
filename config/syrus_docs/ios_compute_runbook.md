# iOS compute readiness runbook

This runbook is for operators preparing Syrus to compile or execute iOS work on
native macOS compute workers. This release supports iOS compilation, SwiftPM
validation, `xcodebuild` simulator runs, and target graders through compute
workers. Coding Mode iOS/editor integration is not part of this release: chat
and editor workspaces still run in the normal worker environment, and iOS work
enters the workflow through Jobs, target configuration, and grader placement.

## Readiness checklist

Before filing iOS work, confirm all of these are true:

- The repository has `.syrus.yml` project or target capability metadata for
  the iOS surface: `os: macos`, usually `arch: arm64`, `toolchain: xcode`, and
  `runtime: ios_simulator`.
- iOS prepare and grader commands are explicit enough to run noninteractively:
  workspace or project, scheme, simulator destination, isolated DerivedData,
  result bundle output, timeout, and any JUnit output path.
- At least one external macOS compute worker heartbeats with matching
  capabilities and consumes the macOS compute queues, such as
  `runs-macos-arm64` and `merges-macos-arm64`.
- `bin/macos-worker-check --env-file /etc/syrus/worker.env` passes on each Mac
  host that should receive iOS work.
- The launchd worker user can access any signing keychain, certificates,
  provisioning profiles, package registries, internal services, and artifact
  storage the target repository needs.
- The Linux home worker and Linux compute pool remain in place for chat,
  polling, indexing, cleanup, control-plane work, backend implementation, and
  backend graders.

## Configure the repository

Use project-level capabilities when the implementation itself needs Xcode
feedback before the first diff exists:

```yaml
# apps/ios/.syrus.yml
project:
  id: ios
  label: iOS App
  kind: ios_app
  capabilities:
    os: macos
    arch: arm64
    toolchain: xcode
    runtime: ios_simulator
```

Use target-level capabilities on the executable work that truly needs the Mac:

```yaml
grade:
  - type: xcodebuild
    workspace: apps/ios/MobileApp.xcworkspace
    scheme: MobileApp
    destination: "platform=iOS Simulator,name=iPhone 16,OS=latest"
    derived_data_path: .syrus/DerivedData/ios
    result_bundle_path: build/syrus/ios/MobileApp.xcresult
    junit_output: build/syrus/junit/ios-tests.xml
    when_files_changed:
      - "apps/ios/**"
      - "packages/api-client/**"
    phases: [review, landing, ci]
    timeout_minutes: 45
```

Backend targets in the same repository should declare Linux requirements when
they need Linux tools or should stay off scarce Mac capacity:

```yaml
grade:
  - name: backend
    run: bin/rspec
    when_files_changed:
      - "app/**"
      - "spec/**"
    capabilities:
      os: linux
```

For common iOS commands, enable the bundled `ios` plugin and prefer its typed
`xcodebuild` and `swiftpm` graders. They generate ordinary Syrus grader
metadata with macOS/Xcode/iOS simulator capabilities, artifact paths, and
timeouts; the scheduler still uses the same generic capability model as every
other target.

## File iOS Jobs

Capability selection happens before the implementation workflow starts. Do not
rely on prose such as "this is an iOS bug" to move a Job to macOS. Syrus uses
declared repository metadata and explicit planned execution requirements.

When filing an iOS-only Job whose implementation needs Xcode, choose or request
primary planned execution with:

```json
{
  "capabilities": {
    "os": ["macos"],
    "arch": ["arm64"],
    "toolchain": ["xcode"],
    "runtime": ["ios_simulator"]
  }
}
```

When filing a mixed iOS/backend Job, plan the mutable implementation workspace
for the most constrained part of the work, usually the iOS project. The Linux
backend graders can still route to Linux workers after the diff exists because
grader fanout uses the affected target metadata, not the implementation
worker's host.

Use smaller Jobs when the work can be split naturally. A backend-only Job
should not request macOS just because a neighboring iOS project exists, and an
iOS Job should not be bundled with unrelated backend cleanup that would make
review and grader placement harder to reason about.

## How placement works

Syrus stores planned primary execution requirements on the Job before launching
the first Workflow. Each Workflow snapshots those requirements, so later
`.syrus.yml` edits do not silently move in-flight implementation work between
worker classes.

Pinned mutable phases inherit the Workflow's primary capabilities:
implementation, response, rebase repair, visual review, and adversarial review
stay with the planned worker class. Syrus does not migrate an active mutable
workspace from Linux to macOS after the agent has started.

After implementation, grader fanout recomputes affected targets from the
actual diff. Immutable distributed grader runs use their own target
capabilities. In a mixed repository, this means an iOS grader can run on a Mac
worker while a backend grader runs on Linux, and the collection step waits for
both results.

If the final diff touches a more constrained target than the implementation
workflow was planned for, Syrus records an
`implementation_capability_escalation` workflow warning. Treat it as a signal
to retry or continue through an explicit checkpoint on a capable worker, split
the work by platform, or verify that target-specific graders fully cover the
change.

## Operate the Mac worker pool

Run native Mac workers beside the Linux cluster, not inside it. In a typical
k3s deployment:

| Tier | Where it runs | Responsibility |
| --- | --- | --- |
| Web and data services | Linux k3s or managed services | App, API, database, object storage, ingress |
| Home worker | One Linux pod | Chat, polling, indexing, cleanup, control-plane, videos |
| Linux compute | Linux pods | Ordinary implementation, backend graders, Linux merges |
| macOS compute | External launchd hosts | Xcode, SwiftPM, iOS simulator, macOS merges |

Mac workers should start through:

```bash
/opt/syrus/current/bin/macos-worker --env-file /etc/syrus/worker.env
```

The env file should force compute-only behavior and advertise the host's
capabilities:

```dotenv
SYRUS_ROLE=worker
SOLID_QUEUE_CONFIG=config/queue.compute.yml
SOLID_QUEUE_SKIP_RECURRING=1
SYRUS_DATA_ROOT=/var/lib/syrus
SYRUS_WORKER_POOL_NAME=macos-xcode
SYRUS_WORKER_CAPABILITIES=os:macos,arch:arm64,toolchain:xcode,runtime:ios_simulator
```

Mac workers are outbound clients. They need access to the production database,
storage, Syrus API host, GitHub and configured remotes, model providers,
package registries, release artifacts, and any target-repository services used
by builds or tests. The cluster does not need inbound SSH to the Mac pool for
normal operation.

Roll Mac workers after the Linux web/worker deployment has run migrations.
Use the drain-aware updater so Syrus stops counting a selected Mac as
compatible capacity, lets active Runs settle, activates the desired release,
and verifies the fresh heartbeat plus macOS/Xcode capabilities before moving
to the next host.

## Inspect missing-capability blockers

When an iOS Workflow is queued with `start_blocked_reason:
no_capable_worker`, inspect the Workflow's `start_blocked_details`,
`run_queue_admission_decision`, and any `run_queue_blocked` artifact. The
payload records:

- the selected queue, such as `runs-macos-arm64`;
- the required capabilities;
- the phase step that needed those capabilities;
- live worker queues and normalized capability snapshots;
- Xcode and simulator probe diagnostics when workers report them;
- drain/update state for Mac workers.

Then check Admin Workers, `read_worker_health`, or `read_queue` for the same
facts. Common causes are:

- no fresh Mac worker heartbeat;
- the worker consumes the wrong queue config;
- `SYRUS_WORKER_CAPABILITIES` is missing or normalized differently than the
  target requires;
- Xcode, Command Line Tools, the Xcode license, or simulator runtimes are not
  ready, so `runtime: ios_simulator` is not advertised;
- every compatible Mac is draining or updating;
- the Job was planned for Linux before the iOS target requirement was known.

Fix capacity and let the normal phase-admission recheck start the Workflow.
If the Job itself was planned for the wrong primary implementation capability,
retry or continue it through an explicit capable-worker path rather than
expecting Syrus to move the mutable workspace automatically.

## Remaining limitations

- Coding Mode iOS/editor integration is deferred. Operators can file and run
  iOS compute Jobs, but the interactive editor/chat workspace is not an iOS
  simulator development environment.
- macOS workers are compute workers only. They should not consume chat,
  polling, indexing, cleanup, videos, or control-plane queues.
- Syrus checks worker capabilities and read-only Xcode/simulator diagnostics;
  it does not manage Xcode installation, license acceptance, signing
  identities, provisioning profiles, or simulator image installation for you.
- Mac host CPU and memory pressure charts may be sparse because some
  low-level health probes are Linux-specific. Capability, queue, disk,
  heartbeat, version, and drain/update state still report normally.
- Mutable implementation work is pinned to its planned worker class. Target
  graders can refine placement after code exists, but implementation does not
  live-migrate between Linux and macOS.
