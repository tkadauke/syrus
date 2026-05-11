# Docker Compose Self-Hosting

Docker Compose is the recommended self-host path when you are not running Syrus on Kubernetes. It runs the Rails web process, the Solid Queue worker, and MySQL:

```bash
cp .env.example .env
$EDITOR .env
docker compose up
```

Open `http://localhost:3000`, create the first user, then add your GitHub and agent credentials under Settings -> Credentials. The first user is promoted to admin automatically.

## Required Environment

`SECRET_KEY_BASE` signs Rails cookies. Generate it with `openssl rand -hex 64`.

`RAILS_MASTER_KEY` decrypts Rails credentials, including Active Record Encryption keys used for stored GitHub and agent tokens. It must match the `config/credentials.yml.enc` bundled with the image or source checkout.

`SYRUS_DATABASE_PASSWORD` is the MySQL password used by Rails. `MYSQL_ROOT_PASSWORD` is only for MySQL administration and initialization.

`SYRUS_DATA_ROOT` is where Syrus stores bare clones, workflow workspaces, and captured agent session data. Compose mounts it as a persistent volume.

`JOB_CONCURRENCY` controls how many long-running agent jobs the worker may run at once.

GitHub and agent credentials are per-user in the UI. Add a GitHub PAT with access to the repositories Syrus should poll and push to; this Compose path does not require `GITHUB_APP_*` env vars. For agents, configure either Claude Code OAuth, Codex API key, or Codex ChatGPT auth.json. Claude Code uses the per-user OAuth token here rather than a global `ANTHROPIC_API_KEY`.

## First-Time Setup

`docker compose up` waits for MySQL, starts the web container, and runs `bin/rails db:prepare` from the container entrypoint before Rails serves traffic. The MySQL init hook creates all four production databases Syrus uses: primary, cache, queue, and cable.

If you need to run setup manually:

```bash
docker compose run --rm web ./bin/rails db:prepare
```

## Operations

Upgrade to the latest full self-host image:

```bash
docker compose pull
docker compose up -d
```

Back up the primary database:

```bash
docker compose exec db mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" syrus_production > syrus_production.sql
```

Back up the cache, queue, and cable schemas too if you need an exact operational snapshot:

```bash
docker compose exec db mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" \
  syrus_production syrus_production_cache syrus_production_queue syrus_production_cable > syrus_all.sql
```

The `mysql_data`, `syrus_data`, and `syrus_storage` Docker volumes hold persistent state. Include them in host-level volume backups if you do not rely only on SQL dumps.

## Health Checks

`docker compose ps` reports service health:

`db` uses `mysqladmin ping`.

`web` checks Rails' `/up` endpoint.

`worker` boots Rails and verifies a recent Solid Queue process heartbeat.

## Reverse Proxy And TLS

Compose intentionally does not include nginx, Caddy, Traefik, or TLS. For public hosting, put Syrus behind your existing reverse proxy and terminate TLS there. Forward HTTP to the Compose web service on `localhost:3000`.

## Evaluation Image

For casual evaluation, use `ghcr.io/tkadauke/syrus:eval-latest` instead. The eval image is for `bin/syrus dev` style trials; this Compose stack is the full self-host deployment with durable MySQL, Solid Queue, Solid Cable, and worker workspaces.
