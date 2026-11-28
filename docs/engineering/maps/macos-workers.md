# macOS workers map

This page lists where the native macOS worker code lives. For how to operate
it, see [the hub](../operations/macos-workers.md); for the traps in changing
it, see [macOS host pitfalls](../pitfalls/macos-hosts.md).

## On the host (shell, macOS only)

| File | Owns | Spec |
| --- | --- | --- |
| `bin/macos-worker` | Worker entrypoint: sources the env file, forces the compute role, sets the revision, activates the toolchain, starts `bin/jobs`. `--check` runs the check on the pinned toolchain | `spec/bin/macos_worker_spec.rb` |
| `bin/macos-worker-check` | Read-only host and env validation, with `OK`/`FAIL`/`WARN` lines | via the installer and updater specs |
| `bin/macos-runtime-env` | Pinned-toolchain library: install, `PATH`, Bundler env, `syrus_macos_runtime_activate` | via the specs above |
| `config/macos_worker_toolchain.env` | mise and MySQL client pins (version, URL, SHA-256); Playwright and `@playwright/mcp` versions | `spec/bin/macos_runtime_env_spec.rb` |
| `.ruby-version`, `.node-version` | Ruby and Node pins, shared with the Linux image | — |
| `bin/install-macos-worker` | Idempotent host provisioning, agent CLI pins, launchd load | `spec/bin/install_macos_worker_spec.rb` |
| `bin/uninstall-macos-worker` | Reverses the installer, keeping config, data, and account by default | `spec/bin/uninstall_macos_worker_spec.rb` |
| `bin/syrus-macos-updater` | Pull updater: poll, verify, prepare, activate, report, prune | `spec/bin/syrus_macos_updater_spec.rb` |
| `config/launchd/com.syrus.worker.plist`, `com.syrus.updater.plist` | Service definitions, `PATH`, logs, `ExitTimeOut` | via the installer spec |

## Release and deploy (deploy machine)

| File | Owns | Spec |
| --- | --- | --- |
| `bin/release-macos-worker` | Builds the source artifact, checksums, and optional `.sig` | `spec/bin/release_macos_worker_spec.rb` |
| `lib/deploy/macos_workers.rb` | `Deploy::MacosWorkers`: `prepare!`, `activate!`, `await!` | `spec/deploy/macos_workers_spec.rb` |

## Server (Rails)

| File | Owns | Spec |
| --- | --- | --- |
| `app/services/macos_worker_release.rb` | Stores uploaded releases, activates them (`rollout: immediate`), reports per-host status | `spec/requests/api/v1/admin/macos_worker_releases_spec.rb` |
| `app/controllers/api/v1/admin/macos_worker_releases_controller.rb` | Operator/deploy API: upload, `activate`, `status` | same |
| `app/controllers/api/v1/app/admin/macos_worker_updates_controller.rb` | Updater API: desired metadata (`enabled`, `drain`), `report`, `artifact`, drain actions | `spec/requests/api/v1/app/admin/macos_worker_updates_spec.rb` |
| `app/services/macos_worker_rollout.rb`, `app/models/macos_worker_drain.rb` | Manual drain-aware updates | `spec/services/macos_worker_rollout_spec.rb` |
| `app/jobs/run_job.rb` (`defer_for_macos_version_skew?`) | Hands a claimed Run back from a skewed Mac | RunJob specs |
| `app/services/run_queue_resolver.rb` (`macos_version_skewed?`) | Excludes skewed or draining Macs from capacity | RunQueueResolver specs |
| `lib/tasks/macos_worker_token.rake` | `syrus:macos_worker_token`, the scoped updater token | — |
| `config/queue.compute.yml` | The queues a Mac consumes | — |

## Docs

- Operations: [hub](../operations/macos-workers.md),
  [host](../operations/macos-worker-host.md),
  [updates](../operations/macos_worker_updates.md), and
  [troubleshooting](../operations/macos-worker-troubleshooting.md).
- Public: `website/src/content/docs/deployment/macos-workers.md`.
- Operator-searchable: `config/syrus_docs/multi_worker.md` and
  `config/syrus_docs/ios_compute_runbook.md`.

When behaviour changes, update the page that owns the topic, as the
[hub's routing table](../operations/macos-workers.md#when-you-need-to-read)
assigns it, then fix any public-doc sentence that summarizes it.

Return to the [maps index](README.md).
