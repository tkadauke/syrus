---
name: configure-syrus-prep
description: Detect package managers and write .syrus.yml so Syrus installs dependencies before each run.
allowed-tools:
  - Read
  - Edit
  - Write
  - Bash(ls:*)
  - Bash(cat:*)
  - Bash(find:*)
---

# Configure Syrus build dependencies

This skill creates or updates `.syrus.yml` with a `prepare` section so Syrus
installs the project's dependencies before invoking the agent each run.

## What to do

1. **Detect package managers** — look for these files in the project root:

   | File | Command |
   |---|---|
   | `Gemfile` | `bundle install` |
   | `package-lock.json` | `npm ci` |
   | `yarn.lock` | `yarn install --frozen-lockfile` |
   | `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
   | `requirements.txt` | `pip install -r requirements.txt` |
   | `pyproject.toml` | `poetry install` or `pip install -e .` |
   | `go.mod` | `go mod download` |
   | `Cargo.toml` | `cargo fetch` |

2. **Read `.syrus.yml` if it exists** — preserve any existing settings. Only
   update the `prepare` key.

3. **Write `.syrus.yml`** — minimal, idempotent commands only:

   ```yaml
   prepare:
     - bundle install
     - npm ci
   ```

4. **Order matters** — if installs depend on each other (e.g. `bundle exec`
   runs after `bundle install`), order the commands accordingly.

## Notes

- Include only the package managers that are actually present.
- Prefer lockfile-respecting commands (`npm ci`, `--frozen-lockfile`) so the
  prepare step is deterministic.
- If `.syrus.yml` already has a `prepare` section, replace it. Don't append
  or duplicate.
- `bundle install` in a Rails app with a `Gemfile.lock` is always safe and
  idempotent — include it even if no gems seem obviously missing.
- `prepare` runs in Syrus' server-side agent workspace before each run.
  `hooks.post_checkout` runs later on a developer's machine through the
  local `syrus checkout` CLI. Do not use checkout hooks as a substitute for
  agent-side dependency setup.
