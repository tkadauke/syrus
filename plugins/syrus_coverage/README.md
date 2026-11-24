# Coverage

Coverage analyzes the coverage reports a repository's graders produce. It merges
them, works out what a change did to coverage (overall and per-file percentages,
which changed lines are covered, the pull-request delta), enforces the
thresholds configured under `coverage:` in `.syrus.yml`, records trend
snapshots, and posts one summary comment on the pull request.

## What It Adds

- `coverage_analyze` (at `workflow:post_implementation`) and `coverage_pr_comment`
  (at `workflow:post_pr`) workflow steps. They run once, after the review and
  grade loops, and only for repositories that configure `coverage:`.
- The `.syrus.yml` `coverage:` block (also `plugins: { syrus_coverage.config }`).
- `syrus_coverage_snapshots` (history behind the trend chart) and
  `syrus_coverage_hit_maps` (per-line hit counts behind the Source browser) tables,
  a daily hit-map TTL sweep, and removal of hit maps when a Job closes.
- The read-only `get_coverage_report` workflow tool and the `coverage-gap-report`
  skill.
- Review-diff coverage gutter data, the "Test coverage" section of the agent
  environment snapshot, and the repository coverage trend and hit-map endpoints.

## Ownership And Boundaries

Ecosystem plugins (Ruby, JavaScript, Go, ...) keep supplying coverage analyzers
through the ecosystem family; that contract, the shared `CoverageAnalysis::Parsers`
and the grader-side capture of declared coverage outputs stay in core.

Coverage is **disableable** because it is advisory: nothing downstream depends on
its steps, so new workflows simply omit them and the `coverage:` block becomes a
configuration diagnostic rather than an error. Recorded data is kept, not purged.
The plugin is named `syrus_coverage` because `lib/coverage.rb` would shadow Ruby's
`coverage` library on the load path.

See `docs/syrus_docs/coverage.md` for the user-facing reference.
