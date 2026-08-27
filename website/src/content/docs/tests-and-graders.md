---
title: Tests and Graders
description: Configure fast review checks, landing checks, CI repair checks, coverage, and test insights.
---

# Tests and Graders

Graders are repository-owned commands that Syrus runs to decide whether agent
work is good enough to continue. Syrus does not rewrite the commands. Put
parallelism, coverage, JSON/JUnit formatters, and CI-only behavior in wrapper
scripts that live in the repository.

## Phases

Each grader can declare the phases where it should run:

- `review`: cheap checks before a human reviews the PR.
- `landing`: checks that must pass immediately before merge.
- `ci`: checks used when Syrus is repairing CI failures.

Example:

```yaml
grade:
  - name: quick-ruby
    run: bin/rspec-focused
    phases: [review]
    junit_output: .syrus/grade-output/rspec-focused-junit.xml

  - name: rspec
    run: bin/rspec-fast
    phases: [landing]
    junit_output: .syrus/grade-output/rspec-junit.xml
    failures: allow_inherited

  - name: rspec-ci
    run: bin/rspec-ci
    phases: [ci]
    junit_output: .syrus/grade-output/rspec-ci-junit.xml
    failures: allow_inherited
```

The practical pattern is to keep review checks fast enough that iteration
feels interactive, then run heavier checks at landing or during CI repair.

## Required and Optional Checks

Graders are required by default. Optional graders still run and appear in the
UI, but they do not fail the workflow by themselves.

```yaml
grade:
  - name: lint-docs
    run: bin/lint-docs
    required: false
```

Use optional checks for early warning signals, not for correctness gates that
must protect the branch.

## Inherited Failures

Some projects allow a Job to pass when a grader failure is already present on
the base revision and the Job did not introduce it. Set
`failures: allow_inherited` for graders where Syrus can compare the branch
result against known base results or structured test cases.

This works best for test runners that produce JUnit. Binary build checks can
still benefit from inherited-failure policy, but they provide less detail than
test-level results.

## JUnit and Test Insights

When a grader writes JUnit output, Syrus ingests individual test cases. The
repository Tests page groups repeated executions into durable test identities,
so operators can find:

- recently failing tests,
- slow tests,
- tests with changing outcomes,
- test history with links back to specific runs.

Prefer stable test names and suites. If a test runner changes names on every
run, Syrus cannot build a useful history.

## Coverage

Coverage belongs in the repository's grader command. Syrus can read configured
coverage artifacts, summarize deltas, and post a PR comment when requested,
but the command itself should decide when coverage is collected.

For large suites, a common setup is:

- no coverage for most review and repair iterations,
- one coverage run for the final or landing path,
- CI-only coverage checks for expensive policies.

## File-Sensitive Graders

Use `when_files_changed` for expensive checks that only matter for certain
paths:

```yaml
grade:
  - name: website-build
    run: npm run build
    phases: [landing]
    when_files_changed:
      - "website/**/*"
      - "package.json"
      - "package-lock.json"
```

This keeps agents from burning time on unrelated checks while preserving the
gate when relevant files change.

## Good Wrapper Scripts

Good grader scripts are deterministic, reasonably quiet, and produce
machine-readable output in a known location. For test suites, prefer a wrapper
such as `bin/rspec-fast` or `bin/rspec-ci` over embedding a long formatter
command directly in `.syrus.yml`.
