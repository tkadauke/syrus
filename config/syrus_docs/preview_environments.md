# Preview Environments

Preview environments run a live copy of a Job branch for review, or a
repository's default branch through **Preview main**. Start and stop them from
the Job or repository preview panel. Workflow agents can use `start_preview`
and inspect configured application logs with `read_preview_log`.

Configure a preview in the owning `.syrus.yml`:

```yaml
preview:
  setup:
    - bundle install
  start: bin/rails server -p $PORT -b 0.0.0.0 -e development
  seed: bin/rails db:prepare db:seed
  health_check: /up
  health_check_timeout_seconds: 60
  logs:
    - log/development.log
  env:
    RAILS_ENV: development
  unset_env:
    - DATABASE_URL
```

`start` may use `$PORT` or `${PORT}`. Setup and seed run before the server and
receive the same environment. Make seeding idempotent because every spin-up
uses a fresh checkout. `env` adds preview-only variables; `unset_env` removes
unsafe inherited values. `logs` lists workspace-relative files available in
the UI and through `read_preview_log`. `health_check_timeout_seconds` changes
the workflow agent's default 60-second startup wait.

Monorepos may define `preview:` in nested `.syrus.yml` files. Commands run from
that project's directory while retaining access to the whole checkout. Job
previews offer affected previewable projects; Preview main offers all
configured projects.

Previews stop after 10 minutes without proxied traffic, and each request resets
that TTL. Failures expose logs and diagnostics. A Job preview that is locally
healthy but unreachable because it binds only to localhost offers **Fix
preview**, which creates a direct Job to change the start command to bind to
`0.0.0.0`.

Internal proxy, control-server, workspace, and failure-record details live in
[preview-environment architecture](../../docs/engineering/architecture/preview-environments.md).
Deployment variables and production setup live in the [preview-environment
runbook](../../docs/engineering/operations/preview-environments.md).
