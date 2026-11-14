# Per-spawn resource limits

The implementation and rollout contract for `per_spawn_resource_limits` is documented in the [feature-flag architecture reference](../architecture/feature-flags.md#perspawnresourcelimits). Operators should enable it only after the target hosts support the configured confinement backend and should monitor rejected execution requests during rollout.
