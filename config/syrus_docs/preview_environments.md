# Preview Environments

Preview environments let operators and reviewers access a live, running copy of the target application for testing before approving a PR. The web process handles subdomain-based routing to the preview service.

## URL routing

Preview environments are accessed via subdomains, not paths:

```
http://preview-{job_id}.{SYRUS_PREVIEW_BASE_DOMAIN}
```

Path-based proxying is intentionally not used — it causes CSRF failures, broken absolute URL generation, and broken redirects in most web frameworks.

## Configuration

### `SYRUS_PREVIEW_BASE_DOMAIN`

Controls the base domain for preview subdomains. Default: `lvh.me`.

| Environment | Setting |
|---|---|
| Local dev | Use the default `lvh.me` — all `*.lvh.me` subdomains resolve to `127.0.0.1` via public DNS, requiring no `/etc/hosts` changes |
| Production | Set to your domain (e.g. `syrus.yourdomain.com`) and add a wildcard DNS record (`*.syrus.yourdomain.com → your web server IP`) |

### `SYRUS_PREVIEW_PORT_MIN` / `SYRUS_PREVIEW_PORT_MAX`

Port range the preview service allocates from when spawning preview apps. Defaults: `20000`–`29999`.

## Architecture

### Web process: `PreviewProxyMiddleware`

The middleware is inserted at position 0 (first in the stack) so preview subdomains are handled before host authorization or SSL redirect middleware can reject them.

For each incoming request:

1. The `Host` header is matched against `preview-(\d+).{base_domain}`.
2. If matched, Syrus looks up a `PreviewEnvironment` with that `job_id` in `running` state.
3. If found: the request is reverse-proxied to the preview app at `internal_host:port`, and `last_activity_at` / `expires_at` are refreshed to extend the TTL.
4. If not found (environment not running, never started, or expired): a 503 response is returned with a message directing the user to the Syrus UI.
5. If the host doesn't match the preview pattern: the request falls through to the normal Rails application.

### Preview service process

The `preview` service (`bin/preview`, `Procfile.dev`) is a separate long-running process that manages preview app child processes. It is not involved in request routing.

## Lifecycle

- Start: operator clicks "Start Preview" in the Syrus UI → preview service spawns the app and runs seed commands.
- Inactivity TTL: 10 minutes of no proxied traffic causes the preview service to stop the environment.
- TTL reset: each proxied request through `PreviewProxyMiddleware` resets `last_activity_at` and extends `expires_at`.

## Production setup

1. Set `SYRUS_PREVIEW_BASE_DOMAIN` to your domain.
2. Add a wildcard DNS record: `*.{your_domain} → your web server IP`.
3. Ensure your TLS terminator (Traefik, nginx, etc.) passes the `Host` header through to Rails.
4. The preview service must run alongside web and worker (`SYRUS_ROLE=preview bin/preview`).
