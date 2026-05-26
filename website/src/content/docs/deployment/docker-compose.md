---
title: Docker Compose
description: Run the full Syrus stack (web, worker, MySQL) with one command.
---

# Docker Compose

Docker Compose is the recommended path for running the real Syrus app
without committing to a cluster. It gives you the web UI, the background
worker, persistent MySQL data, and the full GitHub issue-to-PR loop.

> **Status.** The Compose packaging is tracked separately. Until the
> repository includes the Compose file, treat the command below as the
> target flow rather than a copy-pasteable command from this checkout.

## Start the stack

From the directory that contains the published Compose file:

```bash
docker compose up -d
```

The stack is expected to run these services:

- **web**: Rails app served by Puma/Thrust. This is the browser UI where
  users add credentials, register repositories, inspect Jobs, retry
  failed Workflows, and review transcripts.
- **worker**: Solid Queue worker running pollers, setup steps, agent
  invocations, pushes, PR creation, stale-run cleanup, and workspace
  pruning.
- **mysql**: Primary application database. In production-mode deploys,
  Syrus also uses Rails-backed Solid Cache, Solid Queue, and Solid Cable
  tables.
- **storage volume**: `$SYRUS_DATA_ROOT`, where bare clones and workflow
  workspaces live. Losing this volume does not erase the database, but it
  does erase cached clones and in-progress workspaces.

## First-time setup

Create a `.env` file next to the Compose file. The exact published
template is authoritative; these are the important categories:

```dotenv
RAILS_MASTER_KEY=...
SECRET_KEY_BASE=...
SYRUS_DATABASE_PASSWORD=...
SYRUS_DATA_ROOT=/home/rails/.syrus
```

Syrus stores user credentials with Active Record Encryption, so
`RAILS_MASTER_KEY` must be stable across restarts. If it changes, stored
GitHub and agent credentials cannot be decrypted.

After the containers boot, open the web UI and create the first user.
The first signup becomes an admin. In **Credentials**, add:

- A GitHub personal access token that can read issues, push branches, and
  open pull requests on the repositories Syrus will manage.
- An Anthropic/Claude credential, or a Codex API key / login
  configuration, depending on the agent provider you want to use.
- Your preferred default agent provider.

## Add a repository

1. In the web UI, add a repository by owner, name, default branch, and
   trigger label. The default trigger label is usually `syrus`.
2. Make sure polling is enabled for that repository.
3. In GitHub, create or edit an issue and add the trigger label.
4. Wait for the poller to ingest the issue. A Job should appear in the
   dashboard.
5. Open the Job to watch the Workflow move through `prepare`,
   `implement`, `summarize`, and `pr_open`.
6. Follow the PR link when the run succeeds.

Syrus polls GitHub instead of receiving inbound callbacks, so the Job may not
appear instantly. If nothing appears after a couple of polling intervals,
check the repository's trigger label, token permissions, and whether
polling is enabled.

## Persist data

Keep both MySQL and `$SYRUS_DATA_ROOT` on named volumes or host-mounted
directories. MySQL holds users, encrypted credentials, repositories,
Jobs, Workflows, Runs, logs, artifacts, and the Solid Queue / Solid Cable
state used by the app. `$SYRUS_DATA_ROOT` holds clone caches and workflow
workspaces used by running and recently finished Workflows.

Back up MySQL with `mysqldump`:

```bash
docker compose exec mysql \
  mysqldump -u syrus -p \
    --databases \
    syrus_production \
    syrus_production_cache \
    syrus_production_queue \
    syrus_production_cable \
    > syrus.sql
```

Back up `$SYRUS_DATA_ROOT` with your normal volume backup tool. For a
small install, a filesystem snapshot or `tar` of the mounted data
directory is usually enough. For a team install, back up the database and
data-root volume together so running workspaces and DB state stay in
rough agreement.

## Upgrade

Pull the newer images and restart:

```bash
docker compose pull
docker compose up -d
```

Run database migrations according to the published Compose file's
release notes. If the Compose packaging includes a one-shot migration
service, use that instead of shelling into a long-running container.

## TLS

Compose does not need to own TLS. Put Caddy, Traefik, nginx, or your
existing reverse proxy in front of the web service and terminate HTTPS
there. Caddy is the shortest path for a single host with automatic
certificates; Traefik fits better if you already run a Docker-label-based
edge proxy.

If you're a Ruby developer with the toolchain already, you can also run
from source: `git clone`, `bundle install`, and `bin/dev`. Docker Compose
is recommended because it owns the answers to "what else should I
install?"
