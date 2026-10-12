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

The plugin is intentionally scoped to graders first: grader commands are short,
independent, and already describe their workspace, network profile, timeout,
and resource limits through `ProcessRunner`.
