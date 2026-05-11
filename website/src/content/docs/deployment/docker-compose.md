---
title: Docker Compose
description: Run the full Syrus stack (web, worker, MySQL) with one command.
---

<!-- STUB. Implementation issue: bundled with the deployment docs
     issue. Depends on the "Docker Compose for path #2" issue
     producing a real docker-compose.yml.

     Content brief:
     - The single `docker compose up` command
     - What each container does (web / worker / MySQL / Solid Cable
       if needed)
     - First-time setup: env vars, GitHub PAT, Anthropic key
     - How to add a repo, label an issue, watch the Job appear
     - Persisting data across restarts (volumes)
     - Backup / restore basics
     - Footnote: "If you're a Ruby developer and already have the
       toolchain, you can also run from source: `git clone &&
       bundle install && bin/dev`. The Docker Compose path is the
       recommended one because it owns the answers to 'what else
       should I install?'."
     - Link to Kubernetes path for "I want to run this for real."
-->

# Docker Compose

The recommended path for self-hosted Syrus. One command brings up
the web app, worker, and database.

<!-- TODO: full content -->
