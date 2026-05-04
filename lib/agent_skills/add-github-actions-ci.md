---
name: add-github-actions-ci
description: Add a GitHub Actions CI workflow that runs tests on every push and pull request.
allowed-tools:
  - Read
  - Edit
  - Write
  - Bash(ls:*)
  - Bash(cat:*)
  - Bash(find:*)
---

# Add GitHub Actions CI

This skill adds or improves a `.github/workflows/ci.yml` that runs the test
suite on every push and pull request.

## Decision tree

### Already has `.github/workflows/ci.yml`?

Read it. Look for:
- Missing test step → add it
- Outdated `actions/checkout` or language-setup action versions → update to
  latest and pin with SHA
- No PR trigger → add `pull_request:` to the `on:` block
- No matrix for multiple versions → add one if appropriate

If the file is basically fine, make the smallest improvement that adds real
value rather than rewriting for style.

### No CI workflow yet?

Detect the project type and write from scratch.

## Starter templates

### Ruby / Rails

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: .ruby-version
          bundler-cache: true
      - run: bundle exec rails db:test:prepare
      - run: bundle exec rspec
```

### Node.js

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc
          cache: npm
      - run: npm ci
      - run: npm test
```

### Python

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.x'
          cache: pip
      - run: pip install -r requirements.txt
      - run: pytest
```

### Go

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
      - run: go test ./...
```

## Notes

- Pin action versions to their current latest (v4, v5, etc.). Do NOT use
  SHA pins — maintainability matters more than theoretical supply-chain risk
  for a small project's CI.
- Use the project's own version spec files (`.ruby-version`, `.nvmrc`,
  `go.mod`) rather than hardcoding a version in the workflow.
- Add a `db:test:prepare` step for Rails apps that use a database.
- Keep it minimal: one job that installs and tests. Skip coverage upload,
  linting, or deployment unless the project already has those set up.
