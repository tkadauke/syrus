# Container Execution

Container Execution is a disabled-by-default bundled plugin that contributes an
`Execution::Backend` for grader subprocesses. When enabled and configured with
a Docker launch environment, grader commands run through `docker run` instead
of directly on the worker host.

Core still owns backend selection and fallback. If the plugin is absent,
disabled, or cannot prove the worker can launch Docker with host-visible bind
mounts, `ProcessRunner` uses `Execution::Local`.

The backend maps the execution request onto the container invocation:

- read/write, read-only, and artifact mounts become Docker bind mounts;
- the grader network profile becomes `--network none`;
- memory, CPU, and IO resource limits become Docker cgroup flags;
- `SYRUS_PERSISTENT_MCP_SOCKET`, when present, is mounted at
  `/run/syrus/mcp.sock` and forwarded into the container.

Configuration:

- `SYRUS_CONTAINER_EXECUTION_IMAGE`: container image used for grader commands.
- `SYRUS_CONTAINER_EXECUTION_DOCKER`: Docker-compatible CLI path, default
  `docker`.
- `SYRUS_CONTAINER_EXECUTION_DOCKER_SOCKET`: Docker socket path to check when
  `DOCKER_HOST` is not set, default `/var/run/docker.sock`.
- `SYRUS_CONTAINER_EXECUTION_HOST_PATHS`: comma-separated
  `worker_path=daemon_host_path` mappings. Every declared execution mount and
  MCP socket source must be covered. Use identity mappings only when the Docker
  daemon can resolve the worker path at the same absolute path.
- `SYRUS_PERSISTENT_MCP_SOCKET`: optional worker-local MCP daemon socket path
  to mount into zero-egress grader containers.

The published Docker Compose worker intentionally does not mount the Docker
socket; the `plugin-runtime` service is the only default container with Docker
authority. Container Execution therefore remains unavailable in that topology
until an operator explicitly adds a worker-side Docker launch path and host path
mappings. This keeps the plugin from claiming grader requests that would only
fail at `docker run`.

## Repository Opt-In

Container Execution is selected per repository through `.syrus.yml`, not as an
instance-wide default:

```yaml
execution:
  grader_backend: container_execution
```

That setting applies to root and nested grader targets for the repository. A
single grader can override it with `execution_backend: local` or another
backend name. Selection is conservative: if the plugin is disabled, missing, or
unavailable on a worker, core falls back to `Local`.

The Syrus repository itself opts into `container_execution` for grader Runs as
the first dogfood target. Its target-health and grader-conclusion fingerprints
include the requested backend, so a prior `Local` pass is not reused as proof
that the container backend passed.

## Enable, Disable, And Verify

Enable procedure:

1. Enable the `container_execution` plugin for the instance.
2. Configure workers with `SYRUS_CONTAINER_EXECUTION_IMAGE`,
   `SYRUS_CONTAINER_EXECUTION_DOCKER` or `PATH`, Docker transport access, and
   `SYRUS_CONTAINER_EXECUTION_HOST_PATHS` covering workflow workspaces,
   artifacts, caches, and the MCP socket path when present.
3. Add `execution.grader_backend: container_execution` to the repository's
   root `.syrus.yml`.
4. Let review, landing, and main-branch grader workflows run on unchanged
   commits and compare their pass/fail results with the same grader commands
   forced through `execution_backend: local`.

Disable procedure:

1. Remove or change the repository's `.syrus.yml` backend setting to `local`.
2. Disable the plugin if no other repository is actively using it.
3. Leave the worker Docker configuration in place until queued grader Runs
   drain, then remove it during normal worker rollout.

Observed dogfood baseline:

- The repository configuration is now pinned to request
  `container_execution` for grader Runs.
- The backend still falls back to `Local` when the plugin is unavailable, so a
  disable or worker-configuration rollback does not strand grader workflows.
- Wider rollout should wait for production burn-in evidence showing no
  pass/fail divergence between container and Local grader runs on the same
  commits.
