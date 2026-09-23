# Tailscale

The `tailscale` plugin (`plugins/tailscale/`) exposes a Syrus installation on
the operator's Tailscale network so it can be reached from laptops and mobile
devices away from the local network. It is a self-contained Rails engine
plugin, installed but disabled by default (`default_enabled: false`,
`disableable: true`, category `connectivity`), and hard-depends on the
`plugin_runtime` plugin.

## Configuration

Declared via `config_schema` in `plugins/tailscale/lib/tailscale.rb` and
readable/writable through the plugin config API
(`GET`/`PATCH /api/v1/{app/}admin/plugins/tailscale/config`):

| Key | Type | Required | Description |
|---|---|---|---|
| `auth_key` | `secret_env` (`TS_AUTHKEY`) | yes | Auth key for headless device registration. Set in `.env`. |
| `hostname` | `string` | no | Overrides the device name on the tailnet. |
| `exit_node` | `boolean` | no | Advertise this node as an exit node. Defaults to `false`. |

## `tailscaled` runs in its own privileged container, not the worker

`tailscaled` used to run inside the generic worker process, which is why the
worker container used to carry `NET_ADMIN`/`NET_RAW` and `/dev/net/tun`. It
now runs in its own container (`plugins/tailscale/container`,
`ghcr.io/tkadauke/syrus-plugin-tailscale`), started by Plugin Runtime's
runtime manager through a separate, narrowly scoped **privileged lane**
(`PluginRuntime::PrivilegedService`, `PUT /v1/privileged/{name}` on the
manager) rather than the generic `plugin_runtime:service` point every other
container-backed plugin uses. See
`docs/plans/tailscale-privileged-service-lane.md` for the full design and
threat-model discussion; in short:

- The runtime manager's Go code (`plugins/plugin_runtime/container/internal/privileged`)
  compiles in a fixed image, internal port, `CapAdd: [NET_ADMIN, NET_RAW]`,
  a `/dev/net/tun` device grant, and a named volume for `tailscaled`'s state
  -- none of it caller-supplied.
- The only thing a request may set is env, restricted to exactly
  `TS_AUTHKEY`, `TS_HOSTNAME`, and `TS_EXIT_NODE` -- the same three settings
  this plugin's config schema exposes. There is no "extra flags" passthrough.
- `Tailscale::RuntimeService` (`plugin_runtime:privileged_service`) builds
  that env from `Syrus::PluginSettings`, raising when no auth key is
  configured; `PluginRuntime::ManagedDriver` catches that and reports the
  service as an error without ever attempting to create a container -- the
  same gate `on_enable if auth_key present` used to provide.
- `tailscaled`'s state lives on a named volume (`/var/lib/tailscale`), so it
  survives a container restart/recreation instead of re-registering as a new
  node every time -- fixing a real bug the old `/tmp`-based state had.

On Kubernetes, or any install without the runtime manager, Tailscale is
deployed the same way every other "external" Plugin Runtime service is: an
operator runs the privileged workload themselves (their own `NET_ADMIN`/TUN
grant) and points Syrus at it with `SYRUS_PLUGIN_SERVICE_TAILSCALE_URL`.

## Container lifecycle

The container itself (`plugins/tailscale/container`) owns `tailscaled`: it
spawns it, waits for its local API to answer, runs `tailscale up` with the
configured auth key/hostname/exit-node setting, then `tailscale serve`
forwarding to `TS_SERVE_TARGET` (a fixed value the runtime manager merges in
from its own `SYRUS_INTERNAL_WEB_URL` environment, defaulting to
`http://web:80` -- never caller-supplied). It exposes:

- `GET /healthz` -- unauthenticated, like every other container-backed
  plugin's health endpoint.
- `GET /status` -- unauthenticated, proxies `tailscaled`'s local API:
  `daemon_running`, `connected`, `backend_state`, `hostname`, `tailscale_ips`.
  Never returns the auth key or anything derived from it.

Plugin Runtime's own reconcile tick (`PluginRuntime::Callbacks#on_tick`,
every minute) is what actually starts/replaces the container -- the same
mechanism Git Mirror uses. This plugin's own `Tailscale::Callbacks` has one
job left: keeping `Rails.application.config.hosts` in sync with the tailnet
identity the container reports (`Tailscale::HostAllowlist`, via
`Tailscale::RemoteStatus`), so requests arriving over `tailscale serve` with
the tailnet hostname pass Rails' host-authorization middleware. It only
removes the entries it added, leaving any pre-existing host allowlist entries
intact.

## Admin page

When enabled, **Admin → Tailscale** (`/admin/tailscale`, admin-only) shows
live device status, a copyable `https://<hostname>` URL, and a setup
checklist (auth key set, daemon running). The page fetches
`GET /api/v1/app/admin/tailscale/status`, mirrored at
`GET /api/v1/admin/tailscale/status` for external admin API clients:

```json
{
  "daemon_running": true,
  "connected": true,
  "hostname": "my-box.tail12345.ts.net",
  "tailscale_url": "https://my-box.tail12345.ts.net",
  "auth_key_present": true
}
```

`daemon_running`/`connected`/`hostname` come from the container's own
`/status` endpoint (via `PluginRuntime::Services.endpoint_for("tailscale")`),
not a worker-local Unix socket. Both endpoints return
`404 { "error": "tailscale_plugin_disabled" }` when the plugin is disabled,
matching the `syrus_dev` plugin's gating convention.

The container itself -- its live state, image, logs, and a **Privileged**
badge -- shows up on **Admin → Plugin Services** exactly like Git Mirror's,
via the shared Plugin Runtime admin surface.

## Operator flows

Tailscale has no lifecycle API of its own. Enabling, disabling, restarting,
and inspecting the container all go through the shared Plugin Runtime
surfaces documented in full in `plugin_runtime.md`; this section is the
Tailscale-specific walkthrough of each.

- **Enable** -- turn the plugin on from **Admin → Plugins** and set `auth_key`
  (`TS_AUTHKEY`) under its config. Enabling without an auth key does nothing
  harmful: `Tailscale::RuntimeService.privileged_env` raises, and
  `PluginRuntime::ManagedDriver` reports the service as `error` without ever
  asking the runtime manager for a container -- check **Admin → Plugin
  Services** for that `error` state and its message if the container never
  appears.
- **Disable** -- turning the plugin off removes the container (its named
  volume, and therefore the tailnet node identity, is kept) on the next
  reconcile. To stop it immediately without disabling the plugin, use
  **Stop** on **Admin → Plugin Services**; this *holds* the service so
  reconciling leaves it alone until an operator releases the hold.
- **Restart** -- **Admin → Plugin Services → Restart** on the `tailscale`
  row. Use this after rotating the auth key, changing `hostname`/
  `exit_node`, or when `/status` looks stuck -- the container reads its
  three allowed env vars only at startup.
- **Status** -- **Admin → Tailscale** (`/admin/tailscale`) is the
  Tailscale-specific view: daemon running, connected, the tailnet URL, and
  whether an auth key is configured. It answers from the container's own
  `/status`, so it is accurate only while the container is reachable.
- **Missing runtime** -- two distinct causes collapse into the same
  `daemon_running: false, connected: false` answer on `/admin/tailscale`:
  the `plugin_runtime` plugin itself is disabled or its manager is
  unreachable, or the `tailscale` container hasn't started yet (still
  pulling, no auth key). To tell them apart, check **Admin → Plugin
  Services**: it shows the real state (`unavailable` when the manager can't
  be reached, `error` for a config problem, `pending`/`pulling`/`starting`
  otherwise) rather than a boolean.
- **Service unhealthy** -- the container is running but failing its health
  check (`unhealthy` on **Admin → Plugin Services**, past the grace period).
  Tailscale's own `/status` payload does not distinguish this from "not
  reachable" -- **Admin → Tailscale** just reports `daemon_running: false`.
  Use the Plugin Services row's **Restart** action and **Logs** panel to
  diagnose and recycle it; `docker compose logs -f plugin-runtime` on a
  Compose install shows the manager's own view of the container's health
  checks.

## Admin API compatibility

`GET /api/v1/app/admin/tailscale/status` and
`GET /api/v1/admin/tailscale/status` are unchanged by the migration to the
privileged service lane -- same routes, same response shape (see above),
same `404 { "error": "tailscale_plugin_disabled" }` when the plugin is
disabled. Existing API clients and scripts built against these two endpoints
do not need to change. There is deliberately no Tailscale-specific
enable/disable/restart endpoint, before or after this migration -- that
lifecycle has always gone through Plugin Runtime's shared
`/api/v1/app/admin/plugin_services/*` surface (see `plugin_runtime.md`),
which now also manages the `tailscale` container.

## Upgrading from the worker-embedded daemon

Older Syrus installs ran `tailscaled` inside the worker process
(`Tailscale::DaemonManager`, since removed), which is why older
`docker-compose.yml` files granted the `worker` service `NET_ADMIN`/
`NET_RAW` and `/dev/net/tun`. Upgrading past this change:

1. **Pull the new images.** The worker image no longer installs the
   `tailscale` apt package; a new `ghcr.io/tkadauke/syrus-plugin-tailscale`
   image is what actually runs `tailscaled` now. `./install.sh --docker` (or
   `bin/compose-up` for a source build) pulls both as part of a normal
   update -- no separate step needed.
2. **`plugin-runtime` must be up.** If the Tailscale plugin is enabled, the
   `plugin-runtime` service (this repository's runtime manager container)
   now has to be reachable for Tailscale to run at all, since it is the one
   thing allowed to start the privileged container. `SYRUS_PLUGIN_RUNTIME_URL`
   / `SYRUS_PLUGIN_RUNTIME_TOKEN` are set automatically by the installer; a
   hand-rolled Compose file predating Plugin Runtime needs the
   `plugin-runtime` service block added.
3. **The worker loses `NET_ADMIN`/`NET_RAW`/TUN.** This is intentional and
   requires no operator action -- the worker no longer needs, and no longer
   has, any elevated network capability. If you customized
   `docker-compose.yml` to preserve those grants on `worker`, remove that
   customization; it does nothing useful now and only widens the worker's
   blast radius.
4. **Expect one re-registration.** The very first upgrade starts a brand
   new container with no prior `tailscaled` state, so the node re-registers
   on the tailnet once (a new machine, same auth key). After that, state
   lives on a named volume (`/var/lib/tailscale` inside the container) that
   survives restarts and recreations, fixing the previous behavior where
   every worker restart re-registered the node as new (the old
   `/tmp`-based state never survived a restart at all).
5. **Kubernetes and other external installs are unaffected.** They never
   ran the in-worker daemon path to begin with -- see the "own its own
   privileged container" section above, and `plugin_runtime.md`'s
   Kubernetes note.

See `docs/plans/tailscale-privileged-service-lane.md` for the full design
rationale behind this migration.
