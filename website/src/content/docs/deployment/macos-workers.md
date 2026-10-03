---
title: macOS Workers
description: Run native Mac compute workers for Xcode and iOS simulator workloads.
---

# macOS Workers

Native macOS workers run outside Kubernetes and consume only capability-matched
compute queues. They are for Xcode and iOS simulator work; they are not chat,
search, or control-plane workers.

## Pull-Based Updates

Mac hosts run two launchd services:

- `com.syrus.worker` starts `/opt/syrus/current/bin/macos-worker`.
- `com.syrus.updater` starts `/opt/syrus/current/bin/syrus-macos-updater`.

The updater polls Syrus or `SYRUS_UPDATE_METADATA_URL` for desired release
metadata, downloads the `syrus-worker-macos-*.tar.gz` artifact, verifies its
SHA-256, installs it into `/opt/syrus/releases/<sha>`, runs host-local
dependency setup, flips `/opt/syrus/current`, and restarts the worker service.

The worker env file keeps host-local state outside release directories:
`SYRUS_DATA_ROOT`, storage identity, credentials, logs, and shared dependency
caches remain in stable paths across releases. Old release directories are
kept only inside a bounded retention window for rollback.

Syrus records updater state in worker health. Admin views can distinguish
current, updating, failed, and stale Mac workers from the status each host
reports after polling or activation attempts.

## Rolling Updates

Mac worker updates are drain-aware and roll one host at a time. Syrus marks a
specific storage identity or hostname as draining, stops routing new compatible
Runs to that worker, waits for active Runs and spawned processes to finish,
then asks the host updater to activate the desired release.

After the worker heartbeats at the desired `git_sha`, Syrus verifies the host
still advertises macOS and Xcode capabilities before clearing the drain and
moving to the next Mac. Admin worker health and queue views show drain/update
state, failed updates, stale versions, and force-restart requests. If all Mac
workers are draining or updating, Syrus does not advertise Mac capacity for new
macOS/Xcode Runs.

## Why Pull Instead Of SSH

In k3s deployments, the Linux control plane should not need inbound SSH access
to every Mac mini. A pull updater works through the same outbound network path
the worker already needs for Syrus, keeps host-specific Xcode setup local to
the Mac, and lets each host activate a verified release atomically.
