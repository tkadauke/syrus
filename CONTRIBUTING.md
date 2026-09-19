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
bin/rspec        # RSpec suite, serial (no parallelism, no tag filter)
bin/rspec-fast   # RSpec suite, parallel, excludes :ci_only specs
bin/rspec-ci     # bin/rspec-fast, then the :ci_only specs in an isolated serial pass
bin/test-react   # React/Vitest suite and TypeScript typecheck
bin/test-e2e     # Playwright end-to-end suite (core + plugin specs)
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
suite before opening the PR. For frontend-only work, `bin/test-react` is
usually enough. For backend or cross-cutting work, run `bin/rspec-fast` (not
plain `bin/rspec`) or `bin/test`.

### `bin/rspec-fast` is the normal local and CI loop

The full suite has grown past 9,300 examples; a serial `bin/rspec` run now
takes 50-56+ minutes. `bin/rspec-fast` is what you actually want day to day:
it runs RSpec in parallel across your CPU cores and excludes examples tagged
`:ci_only`. CI's `rspec` job runs `bin/rspec-ci`, which is `bin/rspec-fast`
followed by the `:ci_only` examples in their own isolated, serial pass (see
`spec/spec_helper.rb` and `lib/rspec_ci_only_policy.rb`).

Reach for plain `bin/rspec` only when you specifically need the serial
runner — for example, to reproduce an ordering-dependent failure.

### The `:ci_only` tag

A handful of specs are tagged `ci_only: true` and are excluded by
`bin/rspec-fast` (and by a bare local `bin/rspec` outside of CI). They exist
for checks that are too slow, too environmental, or too broad for a normal
grade loop, but still matter in GitHub Actions — the canonical example is a
spec that mutates schema in-process (migration reversibility) and isn't safe
to interleave with unrelated specs inside a shared parallel worker.

Use the tag sparingly. It is not a way to skip an inconvenient or currently
failing spec — first try to make the spec fast with fakes, dependency
injection, or a narrower assertion. Add `:ci_only` only when the spec
genuinely needs isolation or scope that a normal parallel run can't give it,
and run it locally with `bin/rspec-ci` (or `RUN_CI_ONLY_SPECS=true bin/rspec
--tag ci_only`) before opening the PR.

### End-to-end tests

`e2e/` holds the Playwright suite that exercises the app through a real
browser (login, dashboard, job lifecycle, chat, admin panel, and more).
Plugins can add their own specs under `plugins/<name>/e2e/`. Run the whole
thing, or scope to one Playwright project, with:

```sh
bin/test-e2e                   # core + every plugin
bin/test-e2e --project=core    # just core
```

`bin/test-e2e` provisions everything it needs on a fresh machine: it installs
Node dependencies, downloads a Chromium build if one isn't already available,
and seeds the local database with the deterministic fixtures the specs sign
in against. CI runs this suite in a dedicated `E2E` workflow
(`.github/workflows/e2e.yml`), separate from the main `ci.yml`, because
booting the full app and driving a real browser doesn't fit that job's
budget; it's path-scoped so PRs that can't affect the running app (docs-only
changes, for example) don't pay for it.

Add or update an E2E spec when a change affects a real user-facing flow —
sign-in, job/epic creation, chat, or an admin surface — that unit and
request specs don't already cover end to end.

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

## Known gotchas

A few mistakes are easy to make and expensive to clean up once they reach
production. `CLAUDE.md` documents the full set of project conventions and
past incidents (see its "Conventions" and "Things that bit us" sections); two
are worth calling out explicitly before you open a PR:

- **Migrations must be idempotent.** A bare `add_column`, `remove_column`,
  `add_reference`, or `add_index` will crash a retried production deploy with
  a "duplicate column" (or missing-column) error if an earlier attempt got
  partway through before failing. Guard every migration with an existence
  check (`unless column_exists?(...)`, `unless index_exists?(...)`), in both
  `up` and `down`. Also always generate migration files with
  `bin/rails generate migration <Name>` — never hand-write the timestamp in
  the filename, since two branches picking the same timestamp collide in
  `schema_migrations` on whichever environment merges them first. See
  `CLAUDE.md`'s "Migrations are idempotent" and "Migration timestamps come
  from the generator" entries for the full rationale and the recovery cost
  when this goes wrong.
- **SolidQueue jobs must declare a consumed queue.** `config/queue.yml` only
  consumes specific named queues (`runs`, `merges`, `chat`, `control_plane`,
  `polling`, `indexing`, `cleanup`, `low_priority_maintenance`,
  `connectivity`, `videos`); the `default` queue is not consumed by any
  worker, so anything enqueued there silently never runs. `ApplicationJob`
  already sets `queue_as :control_plane`, so most Syrus jobs are safe, but
  give any new job class an explicit `queue_as` on a real queue — don't rely
  on the framework default. `spec/config/queue_partitioning_spec.rb` guards
  this; run it (it's part of the normal suite) if you add a new job class.

## Code of conduct

This project follows the spirit of the
[Contributor Covenant](https://www.contributor-covenant.org/): be respectful,
assume good intent, and keep discussion focused on the work. Harassment,
personal attacks, and intentionally disruptive behavior are not welcome.

Maintainers may remove comments, close issues, or block contributors whose
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
