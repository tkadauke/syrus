---
title: Docker Compose
description: Run the full Syrus stack (web, worker, MySQL) with one command.
---

# Docker Compose

Docker Compose is the recommended self-host path for running the real
Syrus app without committing to a cluster. It gives you the web UI, the
background worker, persistent MySQL data, and the full GitHub
issue-to-PR loop.

> **Status.** The Compose packaging is tracked separately. Until the
> release artifact includes `compose.yml` and `.env.example`, treat the
> stack commands below as the target flow, not as commands that work from
> this checkout today. The first self-hosted release is expected to ship
> those files; this page documents the intended onboarding path so the
> artifact can be copied directly when it lands.

## What You Need

- Docker with the Compose plugin.
- A public or private GitHub repository you can safely let Syrus modify.
- A GitHub token, or a registered Syrus GitHub App installation, with
  permission to read issues, push branches, and open pull requests.
- A Claude or Codex credential for the agent provider you want to use.
- A stable app hostname. For a laptop-only trial, `localhost:3000` is
  enough. For another user or GitHub App callback flow, put Syrus behind
  HTTPS.

## Start The Stack

From the directory that contains the published Compose files:

```bash
cp .env.example .env
```

Edit `.env` and set at least these values:

```dotenv title=".env"
RAILS_MASTER_KEY=replace-with-the-release-master-key
SECRET_KEY_BASE=replace-with-a-long-random-string
SYRUS_DATABASE_PASSWORD=replace-with-a-database-password
SYRUS_APP_HOST=localhost:3000
SYRUS_ALLOWED_HOSTS=localhost,127.0.0.1
SYRUS_ASSUME_SSL=false
SYRUS_FORCE_SSL=false
SYRUS_GITHUB_REPO=OWNER/syrus
SYRUS_BUG_REPORT_OWNER=OWNER
SYRUS_DATA_ROOT=/home/rails/.syrus
```

Syrus stores user credentials with Active Record Encryption, so
`RAILS_MASTER_KEY` must be stable across restarts. If it changes, stored
GitHub and agent credentials cannot be decrypted.

Generate local secrets with:

```bash
openssl rand -hex 64
```

Then start the stack:

```bash
docker compose up -d
docker compose ps
```

Open `http://localhost:3000` unless you changed `SYRUS_APP_HOST`.

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

## Set Up Syrus

After the containers boot, create the first user in the web UI. The first
signup becomes an admin.

The onboarding page is **Set up Syrus**. Work through it in order:

1. **Account and admin access**: confirm the first user is marked
   complete.
2. **GitHub credentials**: open **Configure GitHub** and add a GitHub
   personal access token, or register and install the Syrus GitHub App.
3. **Agent credentials and provider**: open **Configure agent**, choose
   Claude or Codex, and add that provider's credential.
4. **Repository**: add the first repository Syrus should poll.
5. **First issue or direct job**: for the first PR path, delegate a
   GitHub issue with the repository trigger label.
6. **Watch first job**: track the Job until it closes successfully.

For personal-token setup, the token must be able to:

- Read issues and pull requests on the repositories Syrus will manage.
- Push branches to those repositories.
- Open pull requests.

For provider setup, add one of:

- An Anthropic/Claude credential for the Claude provider.
- A Codex API key or login configuration for the Codex provider.

## First Job And PR

Add a repository in the web UI by owner, name, default branch, and
trigger label. The default trigger label is usually `syrus`. Make sure
polling is enabled.

Then create a small issue and add the trigger label. With the GitHub CLI:

```bash
export SYRUS_TEST_REPO=OWNER/REPO

gh issue create -R "$SYRUS_TEST_REPO" \
  --title "Fix one tiny documentation typo" \
  --body "Please fix one obvious typo or wording issue in the docs." \
  --label syrus
```

Expected path:

1. The poller ingests the labeled issue.
2. A **Job** appears in Syrus.
3. The Job creates an initial **Workflow**.
4. The Workflow runs `prepare`, `implement`, `summarize`, and `pr_open`.
5. The Job page shows the transcript and captured diff.
6. When the Workflow succeeds, the Job page shows the GitHub PR link.
7. The onboarding page reports **Ready for normal operations** after at
   least one Job completes successfully.

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
