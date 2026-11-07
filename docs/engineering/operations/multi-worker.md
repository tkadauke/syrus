# Multi-worker operations

Home and compute workers use the queue partitions in `config/queue.home.yml`
and `config/queue.compute.yml`. Keep exactly one home-worker pod: chat
workspaces are local and do not have worker affinity. Compute workers must not
consume the `chat` queue.

Native macOS workers are installed as launchd services from the release
tarball. Keep their advertised capabilities synchronized with the installed
OS, architecture, toolchains, and runtimes, and verify that their configured
queues have live consumers after upgrades.

Worker disk warnings require reclaiming or expanding the affected worker's
storage before retrying storage-affine work. Do not route an existing mutable
workspace to another worker merely to clear the banner; use the supported
retry/recovery path so workspace ownership remains correct.

For Docker Compose, size worker CPU and `JOB_CONCURRENCY` together. More worker
threads than the assigned CPU and memory can support increases admission
pressure and makes queue latency worse rather than increasing throughput.

Capability matching, affinity, sampling, search storage, and the admin worker
payload are documented in [Multi-worker architecture](../architecture/multi-worker.md).

Return to the [operations index](README.md).
