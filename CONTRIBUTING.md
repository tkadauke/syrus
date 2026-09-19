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
bin/rspec        # RSpec suite
npm run test:react # React/Vitest suite and TypeScript typecheck
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
usually enough. For backend or cross-cutting work, run `bin/rspec` or `bin/test`.

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
