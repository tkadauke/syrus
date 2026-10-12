# Container Execution

Container Execution is a bundled Syrus plugin that can run grader subprocesses
inside a constrained container instead of directly on the worker host.

It is disabled by default. When an admin enables it and sets
`SYRUS_CONTAINER_EXECUTION_IMAGE`, Syrus maps grader execution requests onto
Docker bind mounts, `--network none`, and Docker resource-limit flags. If the
plugin is absent, disabled, or not configured with an image, core falls back to
local execution automatically.

The plugin is intentionally scoped to graders first: grader commands are short,
independent, and already describe their workspace, network profile, timeout,
and resource limits through `ProcessRunner`.
