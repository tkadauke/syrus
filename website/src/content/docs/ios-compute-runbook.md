---
title: iOS Compute Runbook
description: Plan, route, and operate Syrus Jobs that compile or test iOS code on native Mac workers.
---

# iOS Compute Runbook

Syrus supports iOS compilation and execution through native macOS compute
workers. Use this runbook when a repository needs Xcode, SwiftPM, or iOS
simulator validation. Coding Mode iOS/editor integration is deferred: iOS work
is supported through Jobs, planned execution capabilities, repository targets,
and graders, not through an interactive iOS editor surface.

## 1. Prepare the repository

Declare macOS/Xcode requirements in `.syrus.yml`; Syrus does not infer them
from issue text.

```yaml
project:
  id: ios
  label: iOS App
  kind: ios_app
  capabilities:
    os: macos
    arch: arm64
    toolchain: xcode
    runtime: ios_simulator

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
    phases: [review, landing, ci]
    timeout_minutes: 45
```

Mixed repositories should also mark backend graders with Linux requirements
when they should stay on Linux workers:

```yaml
grade:
  - name: backend
    run: bin/rspec
    capabilities:
      os: linux
```

For common commands, enable the bundled iOS plugin and use `type: xcodebuild`
or `type: swiftpm`. The typed graders still produce ordinary Syrus grader
metadata with macOS/Xcode/iOS simulator capabilities, result bundle and
artifact paths, timeouts, and optional JUnit output.

## 2. File the Job with the right primary worker

Capability selection happens before implementation starts. For an iOS-only Job
or a mixed iOS/backend Job whose implementation needs Xcode feedback, choose
primary planned execution like:

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

Plan mixed Jobs for the most constrained implementation work, usually the iOS
project. After code exists, target graders refine placement from the actual
diff: iOS graders can run on Mac workers while backend graders run on Linux
workers, and Syrus waits for all selected grader results.

## 3. Run Mac workers beside Linux

Keep web, data services, the home worker, Linux compute, and Linux backend
graders in the normal Linux deployment. Add Mac hosts as external launchd
compute workers that connect outbound to Syrus, the database, storage, GitHub,
model providers, package registries, and any internal build services.

```dotenv
SYRUS_ROLE=worker
SOLID_QUEUE_CONFIG=config/queue.compute.yml
SOLID_QUEUE_SKIP_RECURRING=1
SYRUS_DATA_ROOT=/var/lib/syrus
SYRUS_WORKER_POOL_NAME=macos-xcode
SYRUS_WORKER_CAPABILITIES=os:macos,arch:arm64,toolchain:xcode,runtime:ios_simulator
```

Before loading launchd, run:

```bash
/opt/syrus/current/bin/macos-worker-check --env-file /etc/syrus/worker.env
```

The check validates Ruby/Bundler, Node/npm, Git, Xcode Command Line Tools,
full Xcode selection, iOS simulator runtimes, required env, and production
credentials without starting queue work.

## 4. Debug no-capable-worker blockers

If an iOS Workflow is blocked with `no_capable_worker`, inspect the Workflow's
blocked details, queue-admission decision, Admin Workers, `read_worker_health`,
or `read_queue`. Look for:

- selected queue, usually `runs-macos-arm64`;
- required capabilities: `os: macos`, `arch: arm64`, `toolchain: xcode`,
  `runtime: ios_simulator`;
- live worker heartbeats and consumed queues;
- Xcode and simulator probe diagnostics;
- drain or updater state for Mac workers.

Typical fixes are to start a Mac worker, correct `SOLID_QUEUE_CONFIG`, update
`SYRUS_WORKER_CAPABILITIES`, install or license Xcode, add the simulator
runtime, clear a stuck drain, or retry the Job with the right primary planned
execution.

## Current limits

- Coding Mode iOS/editor integration is not included in this release.
- Mac workers are compute-only and should not consume chat, polling, indexing,
  cleanup, video, or control-plane queues.
- Syrus reports readiness; it does not install Xcode, accept licenses, manage
  signing identities, install provisioning profiles, or create simulator
  images.
- Target graders can refine placement after a diff exists, but mutable
  implementation work does not live-migrate between Linux and macOS.
