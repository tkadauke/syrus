# Preview Environment Architecture

Preview environments let operators and reviewers access a live, running copy
of the target application. User-facing configuration, tools, and lifecycle
behavior are documented in the [searchable preview guide](../../../config/syrus_docs/preview_environments.md); deployment variables and production setup live in the [operations runbook](../operations/preview-environments.md).

`PreviewEnvironment` belongs to exactly one of `job` or `repository` (never
both, never neither). Job-scoped previews are the PR-review case;
repository-scoped previews (`job_id` nil, `repository_id` set) are the job-less
"Preview main" case. Both flow through the same
`PreviewWorkspace`/`PreviewService`/`PreviewProxyMiddleware` machinery.

## URL routing and authorization

Preview environments are accessed via subdomains keyed on the
`PreviewEnvironment` id:

```
http://preview-{preview_environment_id}.{SYRUS_PREVIEW_BASE_DOMAIN}?token={signed_access_token}
```

The signed `token` query parameter is required for the first request to a
running preview. It is minted only by authenticated app endpoints that already
authorize the current user to see that Job or repository preview, and it is
validated by `PreviewProxyMiddleware` before any traffic is proxied to the
preview app. After a valid token request, the middleware sets a short-lived
`_syrus_preview_environment_access` cookie scoped to the preview origin. The
middleware strips the `token` parameter before forwarding the request.

Path-based proxying is intentionally not used because it causes CSRF failures,
broken absolute URL generation, and broken redirects in most web frameworks.

## Web process: `PreviewProxyMiddleware`

The middleware is inserted at position 0 so preview subdomains are handled
before host authorization or SSL redirect middleware can reject them.

For each incoming request:

1. The `Host` header is matched against `preview-(\d+).{base_domain}`.
2. Syrus looks up a `PreviewEnvironment` with that id in `running` state.
3. The middleware requires either a valid query token or an access cookie for
   that exact environment. Missing, expired, or wrong-environment tokens get a
   401 response.
4. The request is reverse-proxied to `internal_host:port`, and
   `last_activity_at` / `expires_at` are refreshed. Token query parameters are
   removed before forwarding.
5. A missing or non-running environment produces a 503 response.
6. A host that does not match falls through to the normal Rails application.

Access cookies use `SameSite=Lax` so the default local
`http://preview-*.lvh.me` flow works without HTTPS. The proxy sends
`Host: localhost:<port>` and `X-Forwarded-Host: localhost:<port>` so development
frameworks accept the request. It preserves the browser-facing hostname in
`X-Syrus-Preview-Host` / `X-Syrus-Preview-Proto`.

## Control server and logs

The web process does not share a filesystem with the `preview` Deployment.
`GET /api/v1/app/jobs/:job_id/preview/logs` therefore makes an internal HTTP
request to `PreviewControlServer`, which runs inside the preview process and
reads files via `PreviewLogReader`. If that request fails, the API responds
with `503 preview_logs_unavailable` rather than a misleading empty log list.

The `preview` service (`bin/preview`, `Procfile.dev`) is a separate long-running
process that manages preview app child processes. Alongside its poll loop,
`bin/preview` starts `PreviewControlServer` on
`0.0.0.0:SYRUS_PREVIEW_CONTROL_PORT`. Its
`GET /environments/:id/logs?lines=N` endpoint is internal-only and must never
be exposed through public ingress.

## Workspace and process internals

Preview apps do not reuse workflow workspaces. `PreviewWorkspace` materializes
a fresh checkout under
`$SYRUS_DATA_ROOT/previews/<preview_environment_id>/`, runs setup and seed
commands, and starts the app there. Stopping or expiring an environment removes
the checkout and nulls `workspace_path`.

A closed Job remains previewable after landing. Since its PR branch has been
deleted, `PreviewService#workspace_revision_for` selects `revision: :commit_sha`
and checks out `job.landed_sha` from the default branch. Other Job previews
continue to clone by branch name.

Repository-scoped previews clone the repository default branch with no Job
revision override. Clone authentication falls back to `Repository#user` because
there is no Job user. Repository preview endpoints mirror the Job-scoped
endpoints, keyed by `repository_id`; a repository can have one active
repository-scoped preview independently of its Job previews.

Setup, seed, and server child processes are recorded as `SpawnedProcess` rows
with `kind=preview`, including process, command, workdir, and available
Job/repository attribution.

## Failure state and remediation metadata

`PreviewEnvironment#error_reason` is an optional machine-readable tag alongside
`error_message`. The `not_reachable` reason means the app passed its local
health check but could not be reached through the internal proxy host, normally
because it bound only to localhost. Application-level HTTP failures do not get
that tag. The Job detail UI uses `not_reachable` to offer the user-facing
"Fix preview" action described in the searchable preview guide.
