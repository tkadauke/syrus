# Container Execution

Container Execution is a bundled Syrus plugin that can run grader subprocesses
inside a constrained container instead of directly on the worker host.

It is disabled by default. When an admin enables it and configures a Docker
launch environment, Syrus maps grader execution requests onto Docker bind
mounts, `--network none`, and Docker resource-limit flags. If the plugin is
absent, disabled, or unavailable for the worker's Docker/mount topology, core
falls back to local execution automatically.

Availability is deliberately conservative. The worker must have a
Docker-compatible CLI, a reachable Docker transport (`DOCKER_HOST` or
`SYRUS_CONTAINER_EXECUTION_DOCKER_SOCKET`), and
`SYRUS_CONTAINER_EXECUTION_HOST_PATHS` mappings for every bind source the
Docker daemon must see. The published Docker Compose worker does not mount the
Docker socket by default; enabling the plugin without these settings leaves
graders on local execution.

The same backend confines custom-coworker turns for Codex, Claude, Muse, and
Agy. Those turns never fall back to local execution. Each per-turn container
gets only the coworker checkout, the current chat/provider agent home, an
ephemeral tmpfs, and the authorized MCP socket. It runs non-root with a
read-only root filesystem, no capabilities, no-new-privileges, seccomp, and
bounded PID, memory, and CPU resources. The persistent checkout is committed
and merged by the existing coworker lifecycle after the container exits.

Set `SYRUS_CONTAINER_EXECUTION_DEVCONTAINER=true` to use a repository's
`.devcontainer/devcontainer.json` (or root `.devcontainer.json`) as the seed
image for container-backed graders. Syrus pulls `image` declarations and builds
`build` declarations when the deterministic local image is missing. This does
not replace `.syrus.yml` prepare commands or affect local execution. Build
contexts and Dockerfiles must be covered by
`SYRUS_CONTAINER_EXECUTION_HOST_PATHS` so the Docker host receives its own path
rather than the worker-container path. Seed-image builds are locked within one
Docker image store. Workers that connect to the same remote daemon should share
one `SYRUS_CONTAINER_EXECUTION_DOCKER_NAMESPACE`; workers with separate local
daemons use distinct namespaces automatically.
