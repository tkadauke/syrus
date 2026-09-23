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

In `docker-compose.yml` it is the `plugin-runtime` service. `install.sh`
generates `SYRUS_PLUGIN_RUNTIME_TOKEN`, sets `SYRUS_PLUGIN_RUNTIME_URL`
(adding both to an existing `.env` on update), and pins
`SYRUS_PLUGIN_RUNTIME_IMAGE` to the backend's release. The manager image is
optional: if it cannot be pulled, the installer starts the stack without it
(`--scale plugin-runtime=0`) and plugin services stay unavailable.

When the manager stops — `docker compose down`, an update, a daemon restart —
it removes the containers it runs, keeping their volumes, so Compose can remove
the project network; the next reconcile after it starts again recreates every
service still wanted. The containers and volumes carry the
`dev.syrus.runtime.project=<project>` label, which `uninstall.sh`,
`uninstall.ps1`, and the desktop app's test reset use to remove them.

### Images

Every `plugins/<name>/container` is published by `bin/publish-plugin-images`
(called from `bin/publish-image`, and by the release workflow) as
`ghcr.io/tkadauke/syrus-plugin-<name>` — `plugin_runtime` becomes
`syrus-plugin-runtime`, `git_mirror` `syrus-plugin-git-mirror` — with the same
tags as the backend image, for linux/amd64 and linux/arm64. A plugin asks for
the image tagged with the running `SYRUS_VERSION`, or `latest` without one.

`bin/deploy` (Kubernetes) builds and pushes the same images as linux/amd64 at
the deploy's SHA, then pins every Deployment, DaemonSet, or StatefulSet
container running one of them -- found by image, so an operator can name the
workload anything -- and the Flux image overrides to that SHA, so a plugin
service always runs the same commit as the Syrus talking to it.

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

## Admin -> Plugin Services

`/admin/plugin_services` lists every plugin service: its owning plugin, live
state (asked of the runtime manager on each load, or the last reconcile's view
if the manager is unreachable), image, and endpoint, plus managed containers no
enabled plugin wants any more, which the next reconcile removes.

On a managed (Compose) install an admin can:

- **Stop** a service. The container is stopped, not removed, and the service
  is *held*: reconciling leaves it alone instead of starting it again. Holds
  are stored on this plugin's record (`config["held_services"]`), so they
  survive restarts; a hold on a service no enabled plugin wants is dropped.
  While stopped, the owning plugin carries on without it, the same as while
  it starts.
- **Start** a stopped service, or **Restart** a running one. Both release the
  hold and act immediately rather than on the next tick; a service with no
  container yet is ensured instead.
- **Read its logs**: the last 100-2000 lines of stdout and stderr,
  timestamped, optionally refreshed every few seconds.

**Details** appears for a running service whose class implements the optional
`service_details(endpoint:)` (see `PluginRuntime::Service`): headline numbers
and a table the service reports about itself -- for the git mirror, its
repositories and disk use.

**Stored data** lists the volumes plugin services keep (owner, size where
Docker reports it, and whether its service has a container). Disabling a plugin
keeps its volume so re-enabling does not start from scratch; a volume whose
service has no container can be deleted here. The manager refuses to delete one
still in use, and only ever deletes volumes it created for this project.
`plugin:purge[name]` removes a purged plugin's volumes too (Plugin Runtime is a
`purge_contributor`).

On an external (Kubernetes) install the page is read-only: it shows the last
health checks, and actions answer `not_managed`. The API behind the page is
`GET /api/v1/app/admin/plugin_services`, `POST
/api/v1/app/admin/plugin_services/:name/{stop,start,restart}`, and `GET
/api/v1/app/admin/plugin_services/:name/logs?tail=N`, admin only; it talks to
the manager's `POST /v1/services/{name}/{stop,start,restart}` and `GET
/v1/services/{name}/logs?tail=N` (text, at most 5000 lines, 2 MiB).

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

**The one documented exception:** a separately named, structurally isolated
privileged lane (`internal/privileged`, `PUT /v1/privileged/{name}` on the
manager; `PluginRuntime::PrivilegedService` /
`PluginRuntime::DesiredPrivilegedServices` on the Rails side) for a small,
compiled table of known services. At the time of writing that table has
exactly one entry, Tailscale. Even there, a request still cannot accept an
image, capability, device, mount, or network setting -- only a short allowed
env list (three keys, for Tailscale), resolved against a fixed, compiled
`Definition`. Which plugins may even reach this lane is a hardcoded Ruby
constant (`PluginRuntime::DesiredPrivilegedServices::FIRST_PARTY_PRIVILEGED_PLUGINS`)
independent of the Go manager's own compiled table, so a mistake in either
allowlist alone fails closed. See
`docs/plans/tailscale-privileged-service-lane.md` for the full design and
threat-model discussion. Nothing else in this document describes that lane;
everything below still describes the contract every `plugin_runtime:service`
contributor is held to.

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
