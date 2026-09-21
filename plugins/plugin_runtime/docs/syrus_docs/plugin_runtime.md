# Plugin Runtime

Runs the long-lived services that container-backed plugins need, and tells
those plugins where to reach them. Off by default; a plugin that needs it
declares it as a dependency, so enabling that plugin enables this one too.

## Why it exists

Most plugins are Ruby that runs inside Syrus. Some need more: a git mirror
keeps bare clones in sync and answers queries against them, and that is a
service with its own process, disk and lifecycle, not a Rails class. Running
it inside the worker would mean giving the worker whatever the service needs
— and the worker runs agents with shell access.

So a plugin can declare a service, and this plugin runs it as a separate
container. The plugin itself stays Ruby; the container does the work.

## Declaring a service

A plugin contributes one class per service through the `plugin_runtime:service`
point:

```ruby
syrus_plugin "git_mirror" do
  depends_on [ "plugin_runtime" ]
  provides "plugin_runtime:service" => "GitMirror::RuntimeService"
end
```

The class answers `service_name` and `service_spec` — image, port, volumes,
env, health check. `PluginRuntime::Service` documents the contract in full.
The service's source lives in the plugin that owns it, under
`plugins/<name>/container/`, so deleting a plugin deletes its container with
it.

The plugin reaches its service with:

```ruby
PluginRuntime::Services.endpoint_for("git-mirror") # => "http://git-mirror:8080", or nil
```

`nil` means "not usable right now" and covers everything from still pulling to
disabled. **A service must always be optional to the plugin using it**: the git
mirror is a fast path in front of GitHub, and when it is unavailable, requests
go to GitHub as before. `endpoint_for` never makes a network call — it reads
what the last reconcile recorded — so it is safe on a request path.

## Two ways to run

Which one applies follows from configuration.

### Docker Compose: managed

Set `SYRUS_PLUGIN_RUNTIME_URL` and `SYRUS_PLUGIN_RUNTIME_TOKEN` on the web and
worker containers. Syrus then asks the **runtime manager** — this plugin's own
container, `plugins/plugin_runtime/container` — to pull and start each enabled
plugin's service. Enabling a plugin needs no restart: within a minute its image
is pulling, and progress shows in the service's status. Disabling the plugin
removes the container but keeps its data volume, so turning it back on does not
start from scratch.

The runtime manager is the one container given the Docker socket, and it is in
the base Compose stack rather than launched on demand — it cannot start itself.
Syrus never touches Docker directly.

### Kubernetes and everything else: external

Without the manager's address and token, Syrus manages nothing. Deploy each
service yourself — Syrus is not given the power to create workloads — and give
Syrus its address:

```
SYRUS_PLUGIN_SERVICE_GIT_MIRROR_URL=http://git-mirror.syrus:8080
```

The variable is `SYRUS_PLUGIN_SERVICE_<NAME>_URL`, with the service name
upper-cased and dashes turned into underscores. Syrus still health-checks the
address every minute, and hands it out only while it answers.

## What the runtime manager refuses

The worker holds the manager's token and runs agents, so the token has to be
assumed to leak. The manager is built so that holding it buys nothing
dangerous — the checks live in the manager, the one place they bind:

- images only from an allowlist (`RUNTIME_MANAGER_ALLOWED_IMAGE_PREFIXES`,
  default `ghcr.io/tkadauke/`), tagged or pinned by digest; an entry ending in
  `/` is a namespace, anything else one exact repository
- named volumes only, never a host path, never under `/proc`, `/sys`, `/dev` or
  `/etc`
- no privileged mode, capabilities, devices, host networking or published
  ports — not refused so much as impossible to express
- `no-new-privileges` on every container
- a request naming a field the manager does not model is rejected outright, so
  asking for `privileged` fails loudly rather than quietly running without it

## Service states

| State | Meaning |
|---|---|
| `pending` | enabled, not reconciled yet |
| `pulling` | image downloading; progress is in `pull` |
| `starting` | running but not yet passing its health check (up to 60s) |
| `running` | passed its health check — the only state `endpoint_for` hands out |
| `unhealthy` | running and failing its health check past the grace period |
| `stopped` / `error` | exited, or refused by the manager's policy |
| `unavailable` | the runtime manager could not be reached |
| `unconfigured` | external mode with no address set |

## Reconciling

Once a minute, while this plugin is enabled, Syrus ensures every enabled
plugin's service and removes any managed service no plugin wants any more.

Two rules keep that from doing damage:

- **If the manager cannot be reached, nothing is removed.** A blip is not a
  reason to tear down every service.
- **A service whose spec fails to build is kept.** A plugin with a config error
  is broken, but its running container is still wanted.

Statuses are cached for five minutes. If reconciling stops, entries expire and
every service reads as unavailable, so callers fall back rather than trusting
an address nobody has checked recently.
