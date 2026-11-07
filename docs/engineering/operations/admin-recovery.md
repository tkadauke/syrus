# Admin Recovery Operations

This runbook covers restarting deployed Syrus processes. Recovery-tool
semantics live in the [searchable recovery guide](../../../config/syrus_docs/admin_recovery.md), while queue, audit, and frontend mechanics live in [admin recovery architecture](../architecture/admin-recovery.md).

## Restart Web / Worker

The operator console's Maintenance section and `POST /api/v1/admin/restart`
(bearer-token API) / `POST /api/v1/app/admin/restart` (session-authenticated,
used by the React admin UI) restart web and/or worker processes without any
environment-specific code -- no `kubectl`, Kubernetes API access, or RBAC.

The mechanism is a shared-cache poison pill. `Admin::RestartService` writes a
UTC timestamp under `syrus:restart_web` and/or `syrus:restart_worker`;
component `all` writes both. Every server process runs a `RestartWatcher`
background thread started by `config/initializers/restart_watcher.rb`. It polls
its role-scoped key every 10 seconds. On a timestamp newer than its start time,
it logs, sleeps a random 0-20 second jitter, and sends itself `SIGTERM`.

The platform's restart policy then brings the process back: Kubernetes' pod
restart policy, Docker Compose's `restart: unless-stopped`, or foreman in local
development. The jitter staggers replacement in multi-pod deployments. A
fresh process ignores the old timestamp because it predates that process's
boot; the cache entry expires after five minutes.

Restarting `worker` or `all` is refused with `409` (`initiated: false`,
`active_runs: N`) while Runs are queued or running unless the request passes
`force: true`. Restarting `web` alone never checks active Runs. Prefer waiting
for active Runs to finish; force only when the worker itself cannot recover.

Every restart request, including a refused request later forced by the
operator, is recorded with component, source (`api` or `app`), force flag, and
the observed active-Run count in the Recent Admin Actions table.

## Deployment checks

- Verify the web and worker platform definitions have an automatic restart
  policy before using the action.
- Verify all participating processes share the configured Rails cache; a
  process on a different cache cannot observe the poison pill.
- For a rolling web restart, watch readiness and replacement capacity before
  initiating another restart.
- After a worker restart, confirm queued work resumes and inspect the stuck-job
  and worker-health surfaces before applying queue-affinity repair.
