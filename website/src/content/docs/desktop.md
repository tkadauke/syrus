---
title: Desktop App
description: Download the Syrus desktop app — a guided local install, the full web UI in a native window, and a menu-bar inbox. macOS today; Windows in beta.
---

# Desktop App

The Syrus desktop app is the easiest way to run Syrus: download it, open
it, and let it set everything up. No terminal, no clone, no manual
configuration. On macOS, double-click Syrus inside the DMG (the app
installs itself into `~/Applications` and relaunches from there).

**[Download Syrus for Mac](https://github.com/tkadauke/syrus/releases/latest/download/Syrus.dmg)**
— one universal build for both Apple Silicon and Intel · other artifacts on
the [releases page](https://github.com/tkadauke/syrus/releases).

**Windows** is in beta: the app installs and runs Syrus locally on Docker
Desktop (or connects to an existing instance), with the same tray inbox
and bundled CLI. Installers aren't published to the releases page yet —
they ship there once code signing goes live. Setup differences worth
knowing: the local backend needs [Docker
Desktop](https://www.docker.com/products/docker-desktop/) on WSL 2, and
**the app installs it for you** — it downloads the official installer and
runs it silently (per-user, no admin permission, service agreement
pre-accepted), so there is nothing to click. If WSL 2 is missing, the app
offers a one-click elevated install first. Either install may restart
Windows; **Syrus reopens after you log back in and setup continues where
it left off**. State lives
under `%USERPROFILE%\.syrus\`, and the
automatically installed CLI lands in `%LocalAppData%\Syrus\bin` and joins
your user PATH (open a new terminal to pick it up).

## Signing in — no API keys

Connecting the app to a Syrus instance takes only the instance address;
you then sign in with your email and password in the app window, exactly
like the browser. The menu-bar/tray inbox authenticates itself from that
session automatically — you never copy an API token during setup. (The
manual token form remains in Preferences for non-admin accounts on shared
instances.)

## What you get

- **A guided first-run setup.** On first launch, choose between
  installing Syrus locally or connecting to an existing instance your
  team already runs. The local path drives the same Docker install the
  CLI uses (`install.sh --docker`), streamed into a progress view — it
  detects an existing Docker runtime (OrbStack, Docker Desktop, or
  Colima), walks you through installing OrbStack when there is none,
  and adopts a previous CLI install instead of clobbering it.
- **The full Syrus web app in a native window.** Jobs, Epics, chats,
  repositories, insights — everything. External links (GitHub PRs,
  issues) open in your default browser.
- **The menu-bar inbox.** Implemented and failed Jobs, notifications with
  badge counts, approve/retry/feedback actions, and a compose shortcut —
  one keyboard shortcut away. For admins — which includes the first (and
  usually only) user of a local install — signing in inside the app window
  wires the menu bar up automatically; there is no token to copy. If the
  saved token ever goes stale (say, after a full reinstall rebuilt the
  database), the app detects the rejection and re-mints the token the
  next time its window is open and signed in.
  Non-admin users on a shared remote instance paste an API token into
  Preferences instead.
- **The Syrus CLI, batteries included.** The app installs the bundled
  `syrus` CLI automatically at launch (`~/.local/bin` on macOS,
  `%LocalAppData%\Syrus\bin` on Windows — see the [CLI docs](/docs/cli))
  and keeps it current with every app update, already signed in through
  the shared credentials file. When Claude Code or Codex is detected on
  the machine, the app offers (once) to add the Claude Code skill so
  coding agents can drive Syrus from the terminal — also available any
  time from Preferences.
- **Lifecycle management.** The app starts your local Syrus when it
  launches and leaves it running when you quit, so GitHub polling and
  agent runs continue in the background. Start, stop, and restart live
  in the **Backend** menu.
- **Automatic updates.** The app updates itself, and each app release
  pins the exact backend image version it was tested with. After an app
  update, the next launch offers to bring the local backend up to the
  pinned version — the update pulls the new image and restarts the
  backend, so the app asks first instead of doing it behind your back.

## Requirements

- macOS 13 or later (one universal DMG runs on both Apple Silicon and Intel).
- A Docker runtime for the local install: [OrbStack](https://orbstack.dev)
  (recommended; the app guides you through it), Docker Desktop, or
  Colima. Connecting to a remote Syrus instance needs no Docker at all.
- ~2 GB of disk for the backend image, plus whatever your repositories'
  clones need.

## Where things live

| What | Where |
| --- | --- |
| Install configuration (`.env` with your instance secrets, compose file, install log) | `~/.syrus/local/` |
| Databases, clone cache, workflow workspaces | Docker volumes `syrus_syrus-data` and `syrus_syrus-search` |
| Menu-bar / CLI credentials | `~/.syrus/credentials` |
| App settings (window state, hotkey, checkout paths) | `~/Library/Application Support/Syrus/` |

Keep `~/.syrus/local/.env` safe: it holds the encryption keys for your
instance's database. Deleting it while the data volume exists makes the
existing data undecryptable — the app and the installer both guard
against this and will ask you to locate the original `.env` or
explicitly start fresh.

## Coexisting with a CLI install

The app and `./install.sh --docker` manage the same Docker project
(`syrus`). If you installed from a clone before, the app detects the
existing data volume during setup and offers to adopt it — point it at
your original `.env` (it copies the file, never moves it). See the
[Docker Compose](/docs/deployment/docker-compose#driving-the-installer-from-automation)
page for the underlying installer contract.

## Starting over

**Syrus → Run Setup Again…** forgets the app's backend configuration and
reopens the first-run setup — useful after moving your instance, wiping
Docker, or pointing the app at the wrong URL. It never deletes your
credentials or your Syrus data. If the app detects that Docker is healthy
but the Syrus data volume is gone entirely, it offers this itself.

## Uninstall

1. Quit Syrus and stop the stack: **Backend → Stop Syrus** (or
   `docker compose -p syrus stop`).
2. Delete `Syrus.app` from Applications.
3. To remove all data too:
   `docker compose -p syrus down -v` (deletes the database and clone
   cache — irreversible), then delete `~/.syrus/`.
