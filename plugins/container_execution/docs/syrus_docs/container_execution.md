# Container Execution

Container Execution is a disabled-by-default bundled plugin that contributes an
`Execution::Backend` for grader subprocesses and custom-coworker agent turns.
When enabled and configured with a Docker launch environment, accepted commands
run through `docker run` instead of directly on the worker host.

Core still owns backend selection and normal grader fallback. Custom-coworker
turns are fail closed: if the plugin is absent, disabled, or cannot prove the
worker can launch Docker with host-visible bind mounts, the turn fails before
the provider process starts and never falls back to `Execution::Local`.

The backend maps the execution request onto the container invocation:

- read/write, read-only, and artifact mounts become Docker bind mounts;
- the grader network profile becomes `--network none`;
- memory, CPU, and IO resource limits become Docker cgroup flags;
- `SYRUS_PERSISTENT_MCP_SOCKET`, when present, is mounted at
  `/run/syrus/mcp.sock` and forwarded into the container.

Custom-coworker containers receive exactly the turn checkout and that chat's
provider-specific agent home as writable bind mounts, the authorized MCP socket
read-only, and an ephemeral `/tmp`. They run as a configurable non-root user
with a read-only root filesystem, all Linux capabilities dropped,
`no-new-privileges`, seccomp, and bounded processes, memory, and CPU. Worker
data roots, other chat/workflow checkouts and agent homes, clone caches,
application credentials, service-account paths, host process namespaces, and
container-runtime sockets are not mounted. The checkout remains on the worker
volume so the existing coworker commit-and-merge lifecycle preserves intended
changes; the container and tmpfs are removed after every turn.

Configuration:

- `SYRUS_CONTAINER_EXECUTION_IMAGE`: container image used for grader commands.
- `SYRUS_CONTAINER_EXECUTION_DEVCONTAINER`: opt in to repository seed images.
  When true, Syrus reads `.devcontainer/devcontainer.json` and then
  `.devcontainer.json` from the repository's default branch through the
  repository-content providers. An `image` is pulled if it is not already
  local; a `build` declaration is built from the checked-out workspace. This
  replaces only the base image for container-backed graders. The normal
  `.syrus.yml` prepare commands and prepared-workspace archive still apply on
  top, and local execution is unchanged. Build contexts and Dockerfiles are
  translated through `SYRUS_CONTAINER_EXECUTION_HOST_PATHS`, just like bind
  mounts, and an unmapped build path is rejected. Defaults to false.
- `SYRUS_CONTAINER_EXECUTION_DOCKER`: Docker-compatible CLI path, default
  `docker`.
- `SYRUS_CONTAINER_EXECUTION_DOCKER_SOCKET`: Docker socket path to check when
  `DOCKER_HOST` is not set, default `/var/run/docker.sock`.
- `SYRUS_CONTAINER_EXECUTION_DOCKER_NAMESPACE`: stable identity for the Docker
  image store used by seed-image build locks. It defaults to the worker host
  identity plus Docker transport, which prevents unrelated workers with local
  daemons from blocking each other. Set the same explicit value on every worker
  that connects to one shared remote daemon so they reuse one another's builds.
- `SYRUS_CONTAINER_EXECUTION_HOST_PATHS`: comma-separated
  `worker_path=daemon_host_path` mappings. Every declared execution mount and
  MCP socket source must be covered. Use identity mappings only when the Docker
  daemon can resolve the worker path at the same absolute path.
- `SYRUS_PERSISTENT_MCP_SOCKET`: optional worker-local MCP daemon socket path
  to mount into zero-egress grader containers.
- `SYRUS_CONTAINER_EXECUTION_COWORKER_USER`: numeric `uid:gid` for coworker
  turns, default `1000:1000` (the published worker UID/GID).
- `SYRUS_CONTAINER_EXECUTION_COWORKER_PIDS`: coworker PID limit, default `256`.
- `SYRUS_CONTAINER_EXECUTION_COWORKER_MEMORY`: coworker memory limit, default
  `4g`.
- `SYRUS_CONTAINER_EXECUTION_COWORKER_CPUS`: coworker CPU limit, default `2`.
- `SYRUS_CONTAINER_EXECUTION_COWORKER_TMPFS`: coworker `/tmp` size, default
  `256m`.
- `SYRUS_CONTAINER_EXECUTION_SECCOMP`: Docker seccomp profile, default
  `builtin`.

The published Docker Compose worker intentionally does not mount the Docker
socket; the `plugin-runtime` service is the only default container with Docker
authority. Container Execution therefore remains unavailable in that topology
until an operator explicitly adds a worker-side Docker launch path and host path
mappings. This keeps the plugin from claiming grader requests that would only
fail at `docker run`.
