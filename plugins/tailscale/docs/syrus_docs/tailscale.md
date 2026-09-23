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
