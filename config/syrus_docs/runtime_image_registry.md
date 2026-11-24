# Runtime image registry

The Runtime Image Service publishes and distributes runtime images (Syrus bases, repository devcontainers, coworker environments) through one operator-provided OCI registry. The registry is an external dependency, like the database. The `oci_registry` provider is enabled when `SYRUS_RUNTIME_IMAGE_REGISTRY_URL` is set.

## Settings

All settings are environment variables on web and worker processes.

| Variable | Purpose |
|---|---|
| `SYRUS_RUNTIME_IMAGE_REGISTRY_URL` | Registry base URL. Use https; embedded credentials are rejected. |
| `SYRUS_RUNTIME_IMAGE_REGISTRY_REPOSITORY_PREFIX` | Top-level repository path owned by Syrus (default `syrus`). |
| `SYRUS_RUNTIME_IMAGE_REGISTRY_BUILDER_USERNAME` / `_PASSWORD` | Pull + push identity, used only when publishing. |
| `SYRUS_RUNTIME_IMAGE_REGISTRY_WORKER_USERNAME` / `_PASSWORD` | Pull-only identity for resolve, inspect, and pull. |
| `SYRUS_RUNTIME_IMAGE_REGISTRY_ADMIN_USERNAME` / `_PASSWORD` | Pull + delete identity, used only for revoke and delete. |
| `SYRUS_RUNTIME_IMAGE_REGISTRY_TIMEOUT` | HTTP timeout in seconds (default 30). |

Use three distinct registry identities; the registry's token service enforces the scopes.

## Behavior

- Each namespace (base, repository devcontainer, coworker environment) maps to exactly one registry repository; tokens are requested per repository and role.
- Manifest and blob digests are verified locally; a registry answer that disagrees with the expected digest is an error.
- Deployment registry credentials are removed from every workload environment. Workloads that must pull receive a short-lived pull-only token for a single repository.
- Revocation and deletion need a registry that allows manifest deletion.

## Diagnostics

`bin/rails runtime_images:diagnose` checks reachability, https, credential separation, and each role's granted scope (from the token's reported access, or a read-only pull probe when the token is opaque, in which case push/delete are reported as unverified). Output never includes secrets; the task exits non-zero on failure.
