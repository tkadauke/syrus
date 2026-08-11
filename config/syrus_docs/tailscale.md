# Tailscale

The `tailscale` plugin (`plugins/tailscale/`) exposes a Syrus installation on
the operator's Tailscale network so it can be reached from laptops and mobile
devices away from the local network. It is a self-contained Rails engine
plugin, installed but disabled by default (`default_enabled: false`,
`disableable: true`, category `connectivity`).

## Configuration

Declared via `config_schema` in `plugins/tailscale/lib/tailscale/engine.rb`
and readable/writable through the plugin config API
(`GET`/`PATCH /api/v1/{app/}admin/plugins/tailscale/config`):

| Key | Type | Required | Description |
|---|---|---|---|
| `auth_key` | `secret_env` (`TS_AUTHKEY`) | yes | Auth key for headless device registration. Set in `.env`. |
| `hostname` | `string` | no | Overrides the device name on the tailnet. |
| `exit_node` | `boolean` | no | Advertise this node as an exit node. Defaults to `false`. |

## Daemon lifecycle

`Tailscale::DaemonManager` (a singleton) owns the `tailscaled` process. It
only starts inside a worker context (`Tailscale::Callbacks` registers with
`home_queue: :connectivity`, `tick_interval: 30.seconds`) so the daemon runs
once regardless of web replica count:

- `on_boot` / `on_enable` — starts `tailscaled` if `TS_AUTHKEY` is present,
  runs `tailscale up` (optionally with `--hostname`), then `tailscale serve`
  forwarding to `$SYRUS_INTERNAL_WEB_URL` (default `http://web:80`).
- `on_tick` — restarts the daemon if it died, and re-syncs the host allowlist
  once it is confirmed alive.
- `on_disable` / `on_shutdown` — clears the host allowlist entries this
  plugin added, then logs out and stops the daemon.

`Tailscale::HostAllowlist` adds the tailnet DNS name and Tailscale IPs
(queried from the local `tailscaled` API over its Unix socket) to
`Rails.application.config.hosts` so Rails' host-authorization middleware
accepts requests arriving over Tailscale. It only removes the entries it
added, leaving any pre-existing host allowlist entries intact.

## Admin page

When enabled, **Admin → Tailscale** (`/admin/tailscale`, admin-only) shows
live device status, a copyable `https://<hostname>` URL, and a setup
checklist (auth key set, `/dev/net/tun` present, daemon running). The page
fetches `GET /api/v1/app/admin/tailscale/status`, mirrored at
`GET /api/v1/admin/tailscale/status` for external admin API clients:

```json
{
  "daemon_running": true,
  "connected": true,
  "hostname": "my-box.tail12345.ts.net",
  "tailscale_url": "https://my-box.tail12345.ts.net",
  "auth_key_present": true,
  "net_admin_capable": true
}
```

`daemon_running` reflects `Tailscale::DaemonManager#alive?`. `connected` is
only computed when the daemon is running, by querying the same local
`tailscaled` API socket used by `HostAllowlist` — the backend must report
`BackendState == "Running"` or `Self.Online == true`. `net_admin_capable` is
`File.exist?("/dev/net/tun")`, a rough proxy for whether the container has the
`NET_ADMIN` capability `tailscaled` needs to create its TUN device. Both
endpoints return `404 { "error": "tailscale_plugin_disabled" }` when the
plugin is disabled, matching the `syrus_dev` plugin's gating convention.
