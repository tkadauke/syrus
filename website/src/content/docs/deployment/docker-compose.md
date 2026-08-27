---
title: Docker Compose
description: Run Syrus on a single machine (web + worker, SQLite) with one command.
---

# Docker Compose

Docker Compose is the lowest-friction way to run the real Syrus app on a
single machine — your Mac, a laptop, a small box — without a Kubernetes
cluster or a MySQL server. The default path pulls a prebuilt image; the
source-build path is there when you are changing Syrus or need custom
system packages. Either way, you get the web UI, the background worker,
the full agent toolchain, and the GitHub issue-to-PR loop, backed by
SQLite.

This is a **single-host** setup. The repository's `Dockerfile` also backs
the clustered MySQL deployment; the Compose path layers
`docker-compose.yml`, `Dockerfile.local`, `compose.env.example`, and
`bin/compose-up` around it for local SQLite operation.

## 1. Install a container runtime

macOS doesn't run Linux containers natively, so install a runtime. Either
works — pick one:

```bash
brew install orbstack            # fast, lightweight, recommended — bundles Compose
# or:
brew install colima docker docker-compose && colima start
```

> Colima needs the Compose plugin installed separately (`docker-compose`); a
> plain `brew install docker` gives you the `docker` CLI but not the
> `docker compose` subcommand. `bin/compose-up` detects whichever is present
> (`docker compose` or `docker-compose`).

## 2. Bring it up with the prebuilt image

From a checkout of the repo:

```bash
./install.sh --docker
```

The installer:

1. Starts or installs a container runtime when needed.
2. Generates `.env` from `compose.env.example` with fresh secrets
   (`SECRET_KEY_BASE` and the three Active Record encryption keys) on first
   run. `.env` is gitignored — keep it.
3. Pulls `ghcr.io/tkadauke/syrus-backend`.
4. Starts the stack: a one-shot **setup** task (prepares the SQLite
   databases and fixes volume ownership), then **web** and **worker**.

When it finishes, open **http://localhost:3000**. The first signup becomes
the admin, and the first-run wizard walks you through GitHub credentials,
the agent, a repository, and a guided chat to land your first Epic.

```bash
docker compose logs -f web worker   # follow logs
docker compose down                 # stop
./install.sh --docker               # pull updates and restart
```

## Driving the installer from automation

`install.sh --docker` doubles as a headless installer — the Syrus macOS
desktop app drives this exact script during its first-run setup. All flags
are optional; without them the behavior above is unchanged.

| Flag | Effect |
| --- | --- |
| `--non-interactive` | Never prompt; a missing decision is a usage error (exit 2). |
| `--json` | Machine-readable NDJSON events on stdout (`start`, `step`, `log`, `error`, `done`); human-readable output moves to stderr. |
| `--target-dir DIR` | Directory that owns mutable state: `.env` plus a synced copy of `docker-compose.yml`. Compose runs from there. Default: the script's own directory (the clone). |
| `--skip-runtime-install` | Never install Homebrew/OrbStack. An installed-but-stopped runtime is still started; with no runtime at all the script exits 10. |
| `--image REF` | Pin `SYRUS_IMAGE` to a specific tag. The pin is persisted into `.env` so later plain `docker compose up` runs use the same tag. |
| `--port N` | First install only: serve on this port instead of 3000 (sets `SYRUS_PORT` and `SYRUS_APP_HOST` during `.env` generation). |

`step` events carry an `id` from this fixed sequence: `runtime_check`,
`runtime_install`, `runtime_start`, `compose_resolve`, `env_check`,
`env_generate`, `image_pull`, `stack_up`, `health`. The final `health` step
polls the app's `/up` endpoint, so `done` means the web UI actually answers,
not just that containers were created.

Failures are classified by exit code so a driving process can react without
parsing text:

| Exit code | Meaning |
| --- | --- |
| `0` | Success — the app answers on its port. |
| `2` | Usage error (unknown flag, missing mode in non-interactive runs). |
| `10` | No container runtime and `--skip-runtime-install` was set. |
| `11` | A runtime exists but its daemon never became ready. |
| `12` | Docker Compose is not available. |
| `20` | The `syrus_syrus-data` volume exists but `.env` is missing — the encryption-key guard. Restore the original `.env` or wipe with `docker compose down -v`. |
| `30` | Image pull failed for a network or other unclassified reason, and no local copy of the image exists. |
| `31` | The registry denied the pull and no local copy exists. The installer already handles the most common cause itself — a **stale saved Docker login** (docker sends any stored `ghcr.io` credentials with every pull, and an expired token is rejected even for public images) — by running `docker logout` for the registry and retrying, once per run. A `31` that persists means the package is private, the tag is unpublished, the registry genuinely requires a login, or Docker's credential helper is broken — check `~/.docker/config.json` for a stale `credsStore`/`credHelpers` entry. |
| `32` | The image tag does not exist in the registry and no local copy exists. |
| `40` | `docker compose up` failed. |
| `41` | The stack started but never became healthy. |

The pull is retried twice before failing, and a failure that matches the
stale-saved-credential patterns triggers one automatic
`docker logout <registry>` before the retry re-pulls anonymously — no
manual `docker logout ghcr.io` needed. If the pull still fails but the
image already exists in the local Docker image store — a previous install,
or a copy you built yourself — the installer continues with that local copy
instead of exiting with a pull-failure code (30/31/32). That makes fork
development and offline reinstalls
work without registry access: `docker build`/`bin/compose-up` the image
under the pinned name, then run the installer normally.

One `.env` owns an installation. If you first installed from a clone (`.env`
at the repo root) and later point an automated install at a different
`--target-dir`, the guard exits 20 because the data volume exists but that
directory has no `.env` — copy your original `.env` into the target
directory to adopt the existing installation.

## Build or customize the image

From a checkout of the repo:

```bash
bin/compose-up
```

That script:

1. Generates `.env` if it does not exist, using the same local secrets
   rules as the prebuilt installer.
2. Builds the base worker image — the fat agent toolchain (Ruby/Node/Go via
   `mise`, Python + poetry/uv, build tools, db clients, and the `claude-code`
   CLI). **The first build is slow** (it compiles language runtimes); later
   builds are cached.
3. Builds `Dockerfile.local` on top of that base image, applying
   `EXTRA_APT_PACKAGES` when present.
4. Starts the same Compose stack.

Use this path when you are changing Syrus source or need apt packages in
the worker image. If you only want to run the app, use
`./install.sh --docker`.

```bash
docker compose logs -f web worker   # follow logs
docker compose down                 # stop
bin/compose-up                       # restart / pick up changes
```

## What runs

- **web** — Rails app served by Thruster on `localhost:3000`.
- **worker** — Solid Queue worker: pollers, prepare steps, agent runs,
  pushes, PR creation, reapers, and workspace pruning.
- **setup** — a one-shot container that runs `db:prepare` and makes the data
  volume writable by the `rails` user, then exits. `web` and `worker` wait
  for it.
- **syrus-data volume** — `/home/rails/.syrus`, holding the primary **SQLite
  databases** (`db/production*.sqlite3`) and the **clone cache / workflow
  workspaces**.
- **syrus-search volume** — `/home/rails/.syrus-search`, holding the dedicated
  SQLite FTS5 search database at `search.sqlite3`.

Both volumes are persisted across restarts; losing them wipes the local
installation state.

There is no MySQL container and no master key — local mode runs the
production environment against SQLite (`SYRUS_SQLITE=1`) and provides the
encryption keys via environment variables.

## Extending the worker environment

The worker runs your repositories' `prepare` / grader commands, so it needs
their toolchains. Two layers cover this:

- **Language runtimes** — already handled, per-repo, with no image changes.
  `mise` is in the image; put a `.mise.toml` / `.tool-versions` in your repo
  and add `mise install` to its `.syrus.yml` `prepare:`. Out of the box you
  get Ruby, Node, Go, and Python; `mise` can install more (Rust, Java, other
  versions) on demand.
- **System packages (apt)** — set `EXTRA_APT_PACKAGES` in `.env`
  (space-separated) and rerun `bin/compose-up`. They're baked into the worker
  image — reproducible and cached.

  ```dotenv
  EXTRA_APT_PACKAGES="imagemagick ffmpeg libmagic-dev"
  ```

  For anything beyond apt, edit `Dockerfile.local` (it just extends the base
  worker image).

Local source builds use the Docker cache on your machine by default. To also
reuse the registry-backed BuildKit cache written by production deploys, provide
a GHCR token (`$GHCR_TOKEN` or `~/.config/syrus/ghcr-token`) and run:

```bash
SYRUS_DOCKER_REGISTRY_CACHE=1 bin/compose-up
```

That pulls and updates `ghcr.io/tkadauke/syrus:cache`. Override the cache tag
with `SYRUS_DOCKER_CACHE_REF=owner/image:cache` when building from a fork or a
private registry.

The worker runs unprivileged (`uid 1000`, no sudo), so a repo's `prepare:`
**cannot** `apt-get install` — that's why system packages live at the image
layer via `EXTRA_APT_PACKAGES`.

## Configuration

`compose.env.example` is the template; `bin/compose-up` copies it to `.env`
and fills the secrets. Notable values:

- `SYRUS_SQLITE=1`, `SYRUS_DATA_ROOT=/home/rails/.syrus` — SQLite local mode.
- `SEARCH_DATABASE_PATH=/home/rails/.syrus-search/search.sqlite3` — dedicated
  chat full-text search database.
- `SYRUS_APP_HOST=localhost:3000`, `SYRUS_ASSUME_SSL=false`,
  `SYRUS_FORCE_SSL=false` — plain HTTP locally.
- `SYRUS_TERMINAL_HOST=worker` — set by `docker-compose.yml` on the worker
  service so terminal relay sockets advertise an address reachable by the web
  container through Docker's internal DNS. The value stays blank in `.env`.
- `SYRUS_PORT=3000` — host port mapped to the container.
- `SECRET_KEY_BASE`, `ACTIVE_RECORD_ENCRYPTION_*` — generated; keep them
  stable across restarts or stored GitHub/agent credentials can't be
  decrypted. Regenerate a key by hand with `openssl rand -hex 32`.

## Persist and back up

Application data lives in the `syrus-data` and `syrus-search` named volumes.
Back it up by copying the SQLite files out:

```bash
docker compose cp web:/home/rails/.syrus/db ./syrus-db-backup
docker compose cp worker:/home/rails/.syrus-search ./syrus-search-backup
```

A filesystem snapshot or `tar` of the volumes works too. Because database
state and clone/workspace state are split across volumes, snapshot them
together when preserving active runs.

## Uninstall

`uninstall.sh` (macOS/Linux) and `uninstall.ps1` (Windows) at the repo root
reverse `install.sh --docker`, plus the desktop-app artifacts when present.
Interactive by default: the script prints exactly what it will remove and
asks one y/N question. Re-running is always safe — missing artifacts are
skipped, and an unreachable Docker daemon skips only the Docker steps.

```bash
./uninstall.sh              # interactive — prints the plan, asks once
./uninstall.sh --keep-data  # keep all data; remove app, CLI, containers, images
```

What it removes:

- The Compose stack (project `syrus`) and — unless `--keep-data` — its
  volumes (`syrus_syrus-data`, `syrus_syrus-search`).
- Every `*syrus-backend` image (any registry/tag) and `ghcr.io/*/syrus-local`
  dev images.
- `~/.syrus/local` — **its `.env` holds the database encryption keys;
  removing it together with the data volume destroys the local Syrus data
  permanently** (skipped by `--keep-data`).
- `~/.syrus/credentials` (skipped by `--keep-data`).
- The `syrus` CLI: `~/.local/bin/syrus`, or on Windows
  `%LOCALAPPDATA%\Syrus\bin` plus its user `PATH` entry.
- The Claude Code skill at `~/.claude/skills/syrus`.
- The desktop app and its settings (settings skipped by `--keep-data`),
  where present.

Shared tools are never touched: Docker Desktop, OrbStack, Colima, and
Homebrew have their own uninstallers.

| Flag | Effect |
| --- | --- |
| `--yes` | Skip the confirmation prompt. |
| `--keep-data` | Preserve `~/.syrus` (encryption keys, credentials), the Docker data volumes, and the desktop app settings. Still removes the app, CLI, skill, containers, and images — a later reinstall adopts the kept data. |
| `--json` | Machine-readable NDJSON events on stdout (`start`, `step`, `log`, `error`, `done`), the same protocol the installer speaks; implies `--yes`. |

Exit codes: `0` ok (including a declined prompt and "nothing left to
remove"), `2` usage, `1` anything else.

Desktop app users don't need the script directly: **Syrus → Uninstall
Syrus…** in the app menu drives the same teardown — see the
[desktop page](/docs/desktop#uninstall).

## TLS

Compose doesn't own TLS. For a local install you don't need it (plain HTTP on
`localhost`). To expose it, put Caddy, Traefik, or nginx in front of the web
service and terminate HTTPS there, and set `SYRUS_APP_HOST` /
`SYRUS_ASSUME_SSL=true` accordingly.

## Develop from source instead

If you're working *on* Syrus rather than just running it, the bare-metal
path (`bin/setup` then `bin/dev`) gives faster reloads — see the project
README. Compose is the recommended way to **run** it because it owns the
answer to "what else do I need installed?"
