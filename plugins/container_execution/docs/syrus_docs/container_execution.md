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
- `SYRUS_CONTAINER_EXECUTION_DEVCONTAINER`: opt in to repository seed images.
  When true, Syrus reads `.devcontainer/devcontainer.json` and then
  `.devcontainer.json` from the repository's default branch through the
  repository-content providers. An `image` is pulled if it is not already
  local; a `build` declaration is built from the checked-out workspace. This
  replaces only the base image for container-backed graders. The normal
  `.syrus.yml` prepare commands and prepared-workspace archive still apply on
  top, and local execution is unchanged. Defaults to false.
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
