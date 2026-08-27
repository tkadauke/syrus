---
title: Previews and Visual Review
description: Configure repository previews, seed data, preview logs, and browser-based visual review.
---

# Previews and Visual Review

Previews let operators and agents run the repository in development mode from
a Syrus workflow workspace. They power manual preview buttons and browser-based
visual review.

## Preview Configuration

Add a `preview` block to `.syrus.yml`:

```yaml
preview:
  setup:
    - bundle install
    - npm ci
  seed: bin/rails db:prepare db:seed
  start: bin/rails server -p $PORT -b 0.0.0.0 -e development
  health_check: /up
```

Syrus assigns `$PORT`, starts the process under its process monitor, and
proxies traffic through the Syrus host. The app should use relative asset and
API URLs whenever possible. Absolute localhost URLs usually work locally but
break once the preview is behind a proxy and HTTPS origin.

Seed commands should be idempotent. A preview may be started repeatedly on the
same branch while a user or reviewer investigates the change.

## Preview Logs

Preview processes run as tracked spawned processes. Their stdout, stderr,
state transitions, exit status, and recent logs are available from the Job
detail UI and through the preview log tools. When a preview does not boot, read
those logs before assuming the browser is at fault.

## Visual Review

Visual review is an optional loop where a read-only agent starts a preview,
drives a browser, captures screenshots, and submits a structured verdict:

- `approved`: the visible behavior looks correct.
- `needs_work`: the implementation should be revised.
- `skipped`: there was nothing useful to test visually.

Configuration:

```yaml
visual_review:
  enabled: true
  rounds: 1
  when_files_changed:
    - "app/frontend/**/*"
    - "app/views/**/*"
```

Use `when_files_changed` to avoid launching a browser for backend-only work.
The visual reviewer should inspect the running app and screenshots, not run
builds or full test suites. Deterministic build and test checks belong in
graders.

## Making Previews Reliable

For Rails, Node, and similar development servers:

- bind to `0.0.0.0`,
- accept the assigned `$PORT`,
- keep host allowlists broad enough for the preview proxy,
- avoid hard-coded `localhost` URLs in generated HTML,
- seed a small realistic dataset,
- make seeds safe to run more than once.

Syrus itself has extra guardrails because it can preview a copy of Syrus from
inside Syrus. Most applications do not need those special protections.
