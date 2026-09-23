# Contributing to Syrus

Syrus is a Rails and React automation harness for turning GitHub issues,
pull request feedback, scheduled tasks, retries, and rebases into agent runs.
Contributions are welcome when they keep that operating model reliable,
observable, and easy to run.

## Development setup

Start from a clean checkout with Ruby 3.4.10 available. Local development uses
SQLite for dev and test, so MySQL is not required.

```sh
bin/setup
```

`bin/setup` installs dependencies, builds the Go CLI, prepares the database, and
clears logs. It does **not** start the server — run `bin/dev` when you're ready.

After setup, the common local commands are:

```sh
bin/dev          # Rails web, worker, and Tailwind watcher
bin/test         # Ruby, legacy JavaScript, React, and TypeScript checks
bin/rspec        # RSpec suite, run serially (slow; see bin/rspec-fast below)
npm run test:react # React/Vitest suite and TypeScript typecheck
bin/test-e2e     # Playwright E2E suite (e2e/ plus every plugin's own e2e/)
```

## Tests

RSpec is required. Tests are not optional.

Every pull request should include tests for the behavior it changes:

- New behavior needs a spec that fails without the change.
- Bug fixes need a regression spec that reproduces the bug.
- Refactors must keep the existing suite green, and should add coverage when
  they touch under-tested behavior.
- Agent loop, `RunJob`, agent invocation, MCP, and polling changes should use
  the existing test seams instead of shelling out to real agents or calling
  GitHub live.

Run the narrowest useful test while developing, then run the relevant broader
suite before opening the PR. For frontend-only work, `npm run test:react` is
usually enough. For backend or cross-cutting work, run `bin/rspec-fast` (see
below) or `bin/test`.

### `bin/rspec` vs. `bin/rspec-fast`

`bin/rspec` runs the whole suite serially through plain `rspec` — correct, but
slow enough that it isn't the normal local or CI loop. `bin/rspec-fast` is what
you actually want day to day: it shards the suite across parallel workers via
`parallel_tests`, writing merged JSON/JUnit output as it goes. CI itself runs
`bin/rspec-ci`, which wraps `bin/rspec-fast` and then runs the `:ci_only`
examples (see below) afterward in an isolated serial pass.

```sh
bin/rspec-fast                          # full suite, parallelized
bin/rspec-fast spec/jobs/run_job_spec.rb # a single file, still parallelized
RSPEC_PROCESSES=4 bin/rspec-fast        # override worker count
```

Only one `bin/rspec-fast` (or `bin/rspec-ci`) run can be active in a checkout
at a time — it holds a lock file because parallel workers share SQLite test
databases that a second concurrent run would corrupt.

### The `:ci_only` tag

Some specs are too slow, too environmental, or too broad for the normal
parallel grade loop, but still worth running in GitHub Actions — for example
specs that mutate schema in-process (migration reversibility checks) and are
not safe to interleave with unrelated specs inside a shared parallel worker.
Tag those `:ci_only`; `bin/rspec-fast` excludes them, and `bin/rspec-ci` runs
them afterward in their own serial pass. Reach for `:ci_only` sparingly — first
try to make a slow spec fast with fakes, dependency injection, or a narrower
assertion before tagging it out of the normal loop.

### E2E suite

`bin/test-e2e` runs the Playwright suite in `e2e/` (plus each plugin's own
`e2e/` directory) against a real Rails dev-environment server with seeded
fixtures. It provisions its own Chromium build and demo database state, so it
can be run locally with no extra setup. It is not part of `bin/test` or the
default `.syrus.yml` grade loop; CI runs it in a separate, longer-running
workflow (`.github/workflows/e2e-ci.yml`) scoped to paths likely to affect
app behavior.

```sh
bin/test-e2e                     # core + every plugin's E2E specs
bin/test-e2e --project=core      # just e2e/
bin/test-e2e --project=browser   # just the browser plugin's e2e/
```

#### If the Chromium install hangs

`playwright install` downloads to 100% and then hangs in its out-of-process
download helper on some Node versions (seen on Node 26; CI pins Node 22), with
no output and a silent ten-minute lock retry. `bin/test-e2e` skips the install
when the browsers are already present, so provisioning them once by hand is
enough:

```sh
cache=~/Library/Caches/ms-playwright   # ~/.cache/ms-playwright on Linux
base=https://cdn.playwright.dev/dbazure/download/playwright/builds
# The version suffix (1200) and platform must match what
# `npx playwright install --dry-run` prints for your machine.
for pkg in "chromium:chromium-1200:chromium-mac-arm64" \
           "chromium_headless_shell:chromium_headless_shell-1200:chromium-headless-shell-mac-arm64"; do
  name=${pkg%%:*}; rest=${pkg#*:}; dir=${rest%%:*}; file=${rest#*:}
  curl -sSL -o /tmp/$name.zip "$base/${name%%_*}/1200/$file.zip"
  mkdir -p "$cache/$dir" && unzip -q /tmp/$name.zip -d "$cache/$dir"
  touch "$cache/$dir/INSTALLATION_COMPLETE"   # the marker Playwright checks
done
```

Running the suite under Node 22 avoids the problem entirely.

### Known gotchas

A few footguns have bitten real contributors before; see `CLAUDE.md` for the
full list, but two are common enough to call out here:

- **Non-idempotent migrations hang deploys.** Guard every `add_column`,
  `remove_column`, `add_reference`, and `add_index` with an `unless
  column_exists?`/`index_exists?` check — a migration that isn't safe to
  re-run against a partially-migrated database will crash a retried deploy
  indefinitely. See CLAUDE.md's "Migrations are idempotent" note.
- **`ApplicationJob` subclasses must declare a consumed queue.** SolidQueue's
  `default` queue has no worker listening on it (see `config/queue.yml`), so a
  job enqueued there silently never runs. Set `queue_as` to one of the
  consumed queues and see `spec/config/queue_partitioning_spec.rb`, which
  fails CI if a job class drifts onto an unconsumed queue.

## Pull request process

Open a PR with a clear description of the problem, the change, and the tests
you ran. Keep the scope tight: unrelated refactors, formatting churn, and
drive-by cleanup make review harder.

PRs are expected to:

- Preserve existing workflow semantics unless the PR explicitly changes them.
- Follow local conventions in `CLAUDE.md`, especially around migrations,
  three-dot diffs, state-machine guards, and test seams.
- Include or update documentation when operator behavior changes.
- Avoid committing secrets, generated local state, or dependency artifacts.
- Be reviewable as one coherent change.

Generated agent PRs should be reviewed like human PRs. Syrus can automate the
mechanics, but maintainers are still responsible for deciding what lands.

## Code of conduct

This project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md), adapted
from the Contributor Covenant. By participating, you are expected to uphold
it. Maintainers may remove comments, close issues, or block contributors whose
behavior makes collaboration worse for others.

## Reporting bugs

Use GitHub issues for ordinary bug reports. Include:

- What you expected to happen.
- What actually happened.
- Steps to reproduce the problem.
- Relevant logs, screenshots, or job/run IDs.
- Your deployment context, including whether this is local development or a
  self-hosted deployment.

Do not include secrets, GitHub tokens, agent credentials, API keys, or private
repository contents in public issues. For security vulnerabilities, follow
`SECURITY.md` instead.
