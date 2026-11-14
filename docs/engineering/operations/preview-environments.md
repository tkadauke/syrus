# Preview Environment Operations

This runbook covers deployment configuration for preview environments. See
[preview environment architecture](../architecture/preview-environments.md)
for proxy, control-server, workspace, and persistence internals, and the
[searchable preview guide](../../../config/syrus_docs/preview_environments.md)
for repository configuration and user-facing behavior.

## Environment variables

### `SYRUS_PREVIEW_BASE_DOMAIN`

Controls the base domain for preview subdomains. Default: `lvh.me`. Local
development can use that default because all `*.lvh.me` subdomains resolve to
`127.0.0.1`. In production, set it to the deployed Syrus domain and configure
wildcard DNS for that domain.

### `SYRUS_PREVIEW_PORT_MIN` / `SYRUS_PREVIEW_PORT_MAX`

Port range the preview service allocates when spawning preview apps. Defaults:
`20000`-`29999`.

### `SYRUS_PREVIEW_CONTROL_PORT`

Fixed port on which the preview service binds its internal control endpoint.
Default: `4568`. This is separate from the per-environment app port range.

### `SYRUS_PREVIEW_ENVIRONMENT_TOKEN_TTL_HOURS`

Controls the signed preview-access-token lifetime. Default: `24` hours. The
environment's inactivity TTL is independent and still stops previews after 10
minutes without proxied traffic.

## Production setup

1. Set `SYRUS_PREVIEW_BASE_DOMAIN` to your domain.
2. Add a wildcard DNS record: `*.{your_domain} -> your web server IP`.
3. Ensure the TLS terminator passes the `Host` header through to Rails.
4. Run the preview service alongside web and worker with
   `SYRUS_ROLE=preview bin/preview`.
5. Allow the web pod to reach the preview pod's
   `SYRUS_PREVIEW_CONTROL_PORT` over the internal cluster network. Do not expose
   this port through public ingress.

The preview service must share the database and cache configuration used by the
web process and have persistent access to `SYRUS_DATA_ROOT` for its own preview
checkouts. It does not require a filesystem shared with the web pod; log reads
cross the internal control endpoint.
