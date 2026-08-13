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

The proxy sends `Host: localhost:<port>` and `X-Forwarded-Host: localhost:<port>` to the preview app so frameworks such as Rails running in development mode accept the request without app-specific preview host allowlists. Syrus preserves the browser-facing hostname separately in `X-Syrus-Preview-Host` / `X-Syrus-Preview-Proto` for apps that explicitly want to inspect the public preview URL.

Preview command configuration lives in the target repository's `.syrus.yml`:

```yaml
preview:
  setup:
    - bundle install
  start: bin/rails server -p $PORT -b 0.0.0.0 -e development
  seed: bin/rails db:prepare db:seed
  health_check: /up
  logs:
    - log/development.log
  env:
    RAILS_ENV: development
  unset_env:
    - DATABASE_URL
```

`start` may use `$PORT` or `${PORT}`; Syrus replaces it with a dynamically allocated port. `setup` runs first in the fresh preview checkout, then `seed` runs before the server starts. Setup, seed, and server commands receive the same preview environment. Any nonzero setup or seed command fails the preview instead of starting a partially prepared app. `env` sets repository-specific variables and `unset_env` strips inherited variables such as production database URLs. Use these keys for repo-specific preview guardrails rather than hardcoding repository checks into Syrus.

### Seeding must be idempotent

`seed` (or, for auto-detected Rails repos, `SyrusRails::PreviewProvider#seed_command`) runs against a **fresh checkout on every preview spin-up**, not once. A `db/seeds.rb` that isn't idempotent (bare `Model.create!`) fails or duplicates rows on the second preview. The "Seed preview demo data" Job template (`lib/agent_skills/configure-preview-seed-data.md`, exposed via `PromptTemplate`) is a one-time, per-repo onboarding pass an operator runs to make an existing `db/seeds.rb` idempotent, add a demo user and representative sample data if the repo has none, and record how to reach an authenticated/populated view in the repo's `.syrus.yml` `visual_review.seed_notes` (see [`syrus_yml.md`](syrus_yml.md)).

### Preview service process

The `preview` service (`bin/preview`, `Procfile.dev`) is a separate long-running process that manages preview app child processes. It is not involved in request routing.

Preview apps do not reuse workflow workspaces: successful workflow workspaces are cleaned up as part of normal workflow lifecycle. When an operator starts a preview, the preview service materializes a fresh checkout under `$SYRUS_DATA_ROOT/previews/<preview_environment_id>/` at the Job's PR branch, runs preview setup and seed commands there, and starts the app from that checkout.

Each preview server child process is recorded as a `SpawnedProcess` with `kind=preview`, including `pid`, `pgid`, command, workdir, and preview/job identifiers in `resource_attribution`. This keeps preview processes visible in the admin Spawned Processes UI and lets the normal spawned-process supervisor/audit path detect exits and honor operator kill requests.

## Lifecycle

- Start: operator clicks "Start Preview" in the Syrus UI for an implemented, approved, or landing Job → preview service creates a fresh preview checkout, runs setup/seed commands, then spawns the app.
- Inactivity TTL: 10 minutes of no proxied traffic causes the preview service to stop the environment.
- TTL reset: each proxied request through `PreviewProxyMiddleware` resets `last_activity_at` and extends `expires_at`.
- Failure: if the checkout, preview command resolution, port allocation, setup/seed/app start, or health check fails, the environment is marked `failed` with an error message. It must not remain indefinitely in `starting` or `seeding`.

## Production setup

1. Set `SYRUS_PREVIEW_BASE_DOMAIN` to your domain.
2. Add a wildcard DNS record: `*.{your_domain} → your web server IP`.
3. Ensure your TLS terminator (Traefik, nginx, etc.) passes the `Host` header through to Rails.
4. The preview service must run alongside web and worker (`SYRUS_ROLE=preview bin/preview`).
