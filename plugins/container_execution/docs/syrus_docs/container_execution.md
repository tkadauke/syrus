# Container Execution

Container Execution is a disabled-by-default bundled plugin that contributes an
`Execution::Backend` for grader subprocesses and chat agent turns. When enabled
and configured with a Docker launch environment, accepted commands run through
`docker run` instead of directly on the worker host.

Core still owns backend selection and normal grader fallback. Chat agent
containment is opt-in through `AppSetting#contained_chat_execution`, and the
same setting applies to every chat agent — a coworker is not treated
differently from any other chat:

- `off` (default) requests no containment; turns run on the worker.
- `preferred` containerizes a turn when this plugin is enabled, configured, and
  able to prove the worker can launch Docker with host-visible bind mounts, and
  otherwise falls back to `Execution::Local`.
- `required` fails the turn before the provider process starts when no backend
  is available, and never falls back.

`required` is the only mode in which containment is a security boundary rather
than a preference, which is also why it is not the default: this backend is
plugin-provided, and core's contract promises a local fallback when no provider
applies. An earlier version made containment unconditionally fail-closed for
custom-coworker turns, which turned a disabled-by-default plugin into a hard
dependency and failed every coworker chat turn on instances that had never
enabled it. Reach `required` by running `preferred` first and confirming the
fleet actually launches containers.

The backend maps the execution request onto the container invocation:

- read/write, read-only, and artifact mounts become Docker bind mounts;
- the grader network profile becomes `--network none`;
- memory, CPU, and IO resource limits become Docker cgroup flags;
- `SYRUS_PERSISTENT_MCP_SOCKET`, when present, is mounted at
  `/run/syrus/mcp.sock` and forwarded into the container.

Chat agent containers receive exactly the turn checkout and that chat's
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
- `SYRUS_CONTAINER_EXECUTION_COWORKER_NETWORK`: the operator-created,
  per-turn-capable Docker network whose firewall permits traffic only to the
  controlled resolver and egress proxy. `bridge`, `host`, and the cluster
  application network are not suitable. Under `required`, chat agent turns fail closed
  when this is unset.
- `SYRUS_CONTAINER_EXECUTION_COWORKER_DNS`: the controlled resolver address
  reachable on that network. It must refuse or safely resolve private,
  loopback, link-local, cluster, database, and cloud-metadata destinations.
- `SYRUS_CONTAINER_EXECUTION_CODEX_PROXY`,
  `SYRUS_CONTAINER_EXECUTION_CLAUDE_PROXY`,
  `SYRUS_CONTAINER_EXECUTION_MUSE_PROXY`, and
  `SYRUS_CONTAINER_EXECUTION_AGY_PROXY`: credential-free HTTP CONNECT proxy
  URLs for the corresponding provider profile. URLs containing user info,
  query strings, or fragments are rejected so secrets cannot enter Docker
  metadata or process diagnostics.
- `SYRUS_CONTAINER_EXECUTION_SECCOMP`: Docker seccomp profile, default
  `builtin`.

## Coworker egress profiles

Chat agent turns use a provider policy object selected from the pinned
chat provider. The profile allows only that provider's maintained model and
authentication hostnames. MCP stays on the mounted Unix socket and therefore
needs no network destination. Git fetch, push, commit integration, and merge
remain worker-owned lifecycle operations outside the turn container; GitHub is
deliberately absent from every profile. Generic web browsing is not part of a
provider profile. An installation that adds grant-backed web access must give
it a separate hostname-aware proxy profile instead of widening these lists.

The network is defense in depth around proxy environment variables: its
firewall must make the controlled proxy and resolver the only reachable
destinations, so a process cannot bypass policy by clearing `HTTPS_PROXY`.
The proxy must resolve hostnames itself, reject literal and resolved private,
loopback, link-local, cluster/service, database, and metadata addresses, and
apply the `io.syrus.egress-profile` container label to its allowlist. Syrus's
policy contract records denials as `coworker_egress_denied` events containing
only the profile and normalized destination hostname and port. The enforcing
proxy must emit the same sanitized fields at the network boundary, with its
normal log timestamp. Neither layer records URL paths, query strings, headers,
request or response bodies, proxy credentials, or provider credentials.

Endpoint lists live under
`app/services/container_execution/egress_policy/`, one class per provider.
When a provider changes endpoints, update its object and conformance example
together, deploy the proxy allowlist first, and then deploy Syrus. A missing or
malformed network, resolver, provider policy, or proxy URL makes the backend
unavailable and, under `required`, the chat agent turn fails before its provider process
starts. For diagnostics, inspect the worker's backend-unavailable error, then
verify the named Docker network, resolver reachability, provider proxy setting,
and sanitized proxy denial log. Do not temporarily attach the container to the
worker, cluster, or default bridge network to diagnose a denial.

The published Docker Compose worker intentionally does not mount the Docker
socket; the `plugin-runtime` service is the only default container with Docker
authority. Container Execution therefore remains unavailable in that topology
until an operator explicitly adds a worker-side Docker launch path and host path
mappings. This keeps the plugin from claiming grader requests that would only
fail at `docker run`.

## Verified coworker confinement capability

A worker advertises `runtime:confined_coworker` only after Container Execution
is enabled with the Docker transport, MCP socket, dedicated network,
controlled DNS, and every supported provider proxy configured. The live probe
then launches the same non-root, read-only, capability-free per-turn container
shape, verifies every proxy is reachable, and proves that direct public and
cloud-metadata egress are denied. The signal is deliberately fail-closed:
partial configuration or a failed runtime check is diagnostic state, never authorization. Scheduled coworker
runs require this runtime token and therefore surface `no_capable_worker`
rather than falling back to local execution.

Worker capability diagnostics distinguish missing configuration (including a
list of missing settings), a missing probe, and a failed container/egress
verification. Privileged grant availability separately reports an unhealthy
or disabled credential-broker authorization path. Set
`SYRUS_VERIFY_COWORKER_CONFINEMENT=true` on production worker workloads only
after supplying the confinement variables; `bin/deploy` then refuses to
complete a rollout unless a fresh live-worker heartbeat can admit confinement
and the credential broker is healthy.

Pre-pull the configured seed image on candidate workers before rollout. Canary
one worker and verify capability heartbeats plus container startup/teardown
latency and orphan-container counts before widening the pool. Rollback by
disabling privileged coworker grants first, then removing the canary; loss of
the last verified worker suppresses those grants immediately.
