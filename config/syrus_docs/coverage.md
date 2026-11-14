# Coverage Reporting

Syrus can parse test coverage artifacts produced by graders, compute PR-level diff coverage, optionally block workflows on threshold misses, and post a coverage summary comment on the PR.

## Enabling coverage

Configure coverage in `.syrus.yml`:

```yaml
coverage:
  sources:
    - artifact: coverage/lcov.info
      format: lcov
  threshold:
    lines: 80
    pr_lines: 70
  on_miss: warn
  pr_comment: true
  hitmap_ttl_days: 7
```

Your grader command must produce the artifact at the path listed under `sources[].artifact` (relative to the `.syrus.yml` file that declares the coverage block).

## Sources

Each entry under `sources` names a coverage artifact and its format:

| Field | Required | Values |
|---|---|---|
| `artifact` | yes | Path relative to the declaring `.syrus.yml` |
| `format` | yes | `lcov` or `cobertura` |

Multiple sources are merged before threshold evaluation. Use multiple sources when different test suites produce separate reports (e.g., unit tests in lcov + integration tests in Cobertura).

## Project-aware coverage

Coverage may be declared in the root `.syrus.yml` or in nested `.syrus.yml` files. The root coverage block keeps the legacy repository-wide behavior: its sources are read from the repository root, its thresholds apply to the repository aggregate, and existing repositories do not need to change their configuration.

A nested coverage block applies to the project that owns that nested `.syrus.yml`. Its artifact paths are resolved relative to the directory containing that `.syrus.yml`, relative paths inside the coverage file are normalized back to repository-relative paths using that same declaring directory, and thresholds are evaluated for that project only. An explicit `project.path` is reported as project metadata but does not move coverage artifact lookup or path normalization. Syrus reports each affected project's status in the workflow artifact, PR comment, and coverage card.

When root coverage is configured, the top-level repository summary is the root coverage result. When only nested project coverage is configured, Syrus computes a repository aggregate from the configured project results. Projects with coverage blocks are included when their project path is touched by the diff under review; root coverage remains repo-wide.

## Thresholds

| Field | Meaning |
|---|---|
| `threshold.lines` | Minimum overall line coverage percentage (0–100) |
| `threshold.pr_lines` | Minimum line coverage on lines changed in this PR (0–100) |
| `threshold.branches` | Minimum overall branch coverage percentage (0–100) |

Omit a threshold field to skip that check. `lines` and `pr_lines` are evaluated together against `on_miss` below; a miss on either triggers that behavior.

`threshold.branches` behaves differently on purpose: a miss never triggers
`on_miss` and never fails coverage analysis. Instead, it records a workflow
warning with a suggested prompt to add tests for uncovered branches. See
`workflow_warnings.md`.

## on_miss

What Syrus does when coverage falls below the threshold:

| Value | Behavior |
|---|---|
| `warn` (default) | Logs a warning; workflow continues |
| `block` | Fails the `coverage_analyze` step; agent must add tests |
| `schedule` | Triggers a follow-up coverage-fix Job |

## pr_comment

When `pr_comment: true`, Syrus posts a formatted coverage summary as a PR comment after the `coverage_analyze` step. The comment includes overall line coverage %, PR-diff coverage %, and per-file breakdown.

## Review diff gutter

When coverage diff annotations are available for the selected review version, the Job detail Review tab offers a `PR coverage` metric gutter. It marks added diff lines as covered, uncovered, or not executable without exposing the full coverage artifact or raw hit-map data in the source diff payload. Historical review versions and explicit SHA ranges only show the gutter when matching coverage annotations are available.

## hitmap_ttl_days

How long per-file line hit data is retained. Default: 7 days. Coverage
summaries and PR annotations persist; only the raw hit map expires.

## Which phase collects coverage

`coverage_analyze` runs only in review-phase workflows — initial, retry,
base-refresh retry, and PR/chat feedback. Landing, promotion, and CI workflows
have no such step, so a coverage artifact they produced would be collected and
then never read.

Typed framework graders therefore instrument the **review** entry only. A grader entry declaring
`coverage: true` whose phases do not include `review` synthesizes an
uninstrumented command and declares no `coverage_outputs`.

This matters most at landing. Coverage roughly doubles a suite's wall clock,
and a landing grader is racing a per-grader `timeout_minutes` that decides
whether a merge train lands or rebuilds from scratch — so instrumentation there
spends the budget twice: once on the clock, once on the artifact nobody reads.

Because review runs the *focused* variant of a typed grader, review coverage is
measured over the specs related to the changed files rather than the whole
suite. `threshold.pr_lines` reads correctly from that sample; a repository-wide
`threshold.lines` evaluated against it will read low, so prefer `on_miss: warn`
for the overall threshold or set `pr_lines` alone. A custom `run:` grader
decides its own instrumentation and is not subject to the phase rule.

## Cognitive debt queue

Repository detail pages include a Cognitive Debt tab that combines coverage,
human review signals, recent churn, and target health to rank files needing
attention. It labels evidence as covered, stale, or blind and explains ranking
signals such as low coverage, high churn, complexity, or unhealthy targets.
Cognitive coverage is a proxy for human engagement, not proof of understanding.

## Formats

### lcov

Standard lcov format (`coverage/lcov.info`). Generated by most Ruby (SimpleCov)
and JavaScript (Istanbul/c8/nyc) test runners, plus language-specific converter
tools.

Coverage artifacts are produced by the review-phase grader pass. Typed framework graders can own coverage toggles and artifact paths directly; custom `run:` graders should produce the configured coverage artifact themselves.

### Cobertura

XML-based format (`coverage/cobertura.xml`). Generated by pytest-cov (Python), JaCoCo (Java), and many CI systems' built-in coverage reporters.

### Native Go (`go-cover`)

Go coverage profiles produced by `go test -covermode=atomic
-coverprofile=coverage.out ./...` can be consumed directly when the bundled Go
plugin is enabled:

```yaml
coverage:
  sources:
    - artifact: coverage.out
      format: go-cover
```

The `set`, `count`, and `atomic` profile modes are supported. No `gocov`,
`gocov-xml`, or `gcov2lcov` installation is required. Overall and per-file
percentages use Go's statement counts; changed-line annotations project each
statement block onto the source lines it spans. Module-qualified paths are
resolved with the nearest `go.mod`.
