# Test Insights (Flaky Tests)

Syrus can ingest structured per-test results from a grader run and turn them
into durable `TestRun`/`TestCase` history, grouped under one durable
`TestIdentity` per `(repository, suite_name, name)` test. `TestIdentity` is
the searchable/navigable object; `TestCase` is an individual execution row.
Together they power per-test pass/fail timelines, duration history, and flaky
test reporting. This is a core feature (not a plugin) —
`test_result_parser` is a plugin *extension point* that lets a repository's
test runner supply its own parsing logic, but storage, flakiness scoring, and
the UI are built into core.

## Enabling ingestion: `junit_output`

Add `junit_output:` to a grader entry in `.syrus.yml`, pointing at a file path
(relative to the repo root) that the grader's command produces:

```yaml
grade:
  - name: rspec
    run: bin/rspec --format progress --require rspec_junit_formatter --format RspecJunitFormatter --out .syrus/grade-output/rspec-junit.xml
    junit_output: .syrus/grade-output/rspec-junit.xml
```

After the grader command runs (pass or fail), `Steps::Grader#ingest_test_output!`
(`app/services/steps/grader.rb:99,156-186`) reads the file at that path and
writes one `TestRun`, one `TestCase` row per parsed case, and links each case
to its stable `TestIdentity`, tagged with the grader's name.
A missing file is not an error — it logs
`"junit_output ... not found — skipping ingestion"` and moves on, so a
`junit_output` path that's only produced by one variant of a grader (see
below) doesn't break the others. A parse failure is also non-fatal: it's
logged as a warning and the grader's pass/fail outcome is unaffected either
way — ingestion never blocks the workflow.

Only one file path is supported per grader Step; if your test command fans
out across multiple parallel workers (see the caveat below), point
`junit_output` at a single merged/aggregated results file, or leave it unset
for that variant.

## How the file gets parsed: the `test_result_parser` extension point

`ingest_test_output!` tries every registered `test_result_parser` plugin
provider in registration order (`Syrus::PluginRegistry.providers_for(:test_result_parser)`),
calling `can_parse?(output_path:, format_hint: nil)` on each; the first
provider that returns `true` handles the file via `call(output_path:, format_hint: nil)`.
If no plugin claims the file, core falls back to `JunitXmlParser`, which
parses standard JUnit XML (`<testsuite>`/`<testsuites>` with `<testcase>`
elements, `<failure>`/`<error>`/`<skipped>` children).

A parser's `call` must return an object duck-typed to
`JunitXmlParser::ParsedRun`: it responds to `total_count`, `passed_count`,
`failed_count`, `skipped_count`, `error_count`, `duration_ms`, and `cases`,
where each element of `cases` responds to `name`, `suite_name`, `file_path`,
`status`, `duration_ms`, `output`, `failure_message`, `failure_backtrace`.
See `lib/syrus/plugin/test_result_parser.rb` for the full contract and
`plugins/rails/lib/syrus_rails/rspec_parser.rb` (`SyrusRails::RspecParser`)
for a reference implementation.

`format_hint` is currently always `nil` for `test_result_parser` calls — it
exists in the interface for parity with `coverage_analyzer` (which does thread
a `format:` value from `.syrus.yml` through), but `ingest_test_output!` doesn't
read a format hint from the grader config today. Parsers must decide
`can_parse?` from the file's content or extension alone.

### Why this repo's own rspec grader uses JUnit XML, not `SyrusRails::RspecParser`'s native format

`SyrusRails::RspecParser` can parse RSpec's plain progress/documentation
output directly — no `rspec_junit_formatter` gem required — by content-sniffing
for an `N examples, N failures` summary line. That's the right choice for a
repo that hasn't configured a JUnit formatter. But RSpec's default output only
lists *failing* examples individually (passing/pending examples aren't named
in the text); `SyrusRails::RspecParser` therefore only ever creates `TestCase`
rows with `status: "failed"`. Since `TestCase.top_flaky_tests` (and
`TestCase.flakiness_score`) require a test to have **both** a passed and a
failed row within the lookback window to count as flaky, the native-text route
can never actually detect a flaky test — it can only ever accumulate failures.

This repo's own `.syrus.yml` grader instead adds the `rspec_junit_formatter`
gem (`group :test` in the `Gemfile`) and asks `bin/rspec` for a second,
JUnit-formatted output stream alongside the normal progress output that
appears in the grade log:

```
bin/rspec spec plugins --format progress --require rspec_junit_formatter --format RspecJunitFormatter --out .syrus/grade-output/rspec-junit.xml
```

Because JUnit XML enumerates every example (passed, failed, and skipped),
`JunitXmlParser` (the core fallback — `SyrusRails::RspecParser.can_parse?`
declines XML content, since it doesn't match the progress-format summary
line) creates one `TestCase` row per example per grader Run, giving
`TestCase.top_flaky_tests` real signal.

`junit_output` is attached to the grader entry that produced it, independent of
phase. If a repository has separate landing and CI commands (for example
`rspec` and `rspec-ci`), both entries should declare their own `junit_output`
path so Syrus can ingest the results from either phase. Wrapper scripts that
fan out across `parallel_tests` workers should merge their per-worker XML files
before exiting.

## Flakiness scoring

`TestCase.flakiness_score` (`app/models/test_case.rb`) looks at the most
recent `FLAKINESS_LOOKBACK` (default 20) rows for a given
`(repository, suite_name, name)` tuple, ordered by `created_at` descending. A
test is flaky if that window contains at least one `passed` row and at least
one `failed`/`error` row; the score is `failed / total` within the window.
`TestCase.top_flaky_tests(repository:, lookback:, limit:)` runs the same logic
as a single SQL query (window functions) to rank the flakiest tests
repository-wide. `TestCase.batch_flakiness` does the same lookup for an
arbitrary set of test cases in one query, used to annotate a single Job's test
results without an N+1.

## Where it surfaces

- **Repository Tests tab** — `GET /api/v1/app/repositories/:repository_id/tests`
  (`Api::V1::App::RepositoryTestsController#index`) returns interesting recent
  failures by default and supports search by test name/suite/file. Clicking a
  row opens `GET /api/v1/app/repositories/:repository_id/tests/:id`, which
  shows that `TestIdentity`'s execution history, links to the individual Runs,
  and a duration-over-time graph.
- **Job test results** — `GET /api/v1/app/jobs/:job_id/test_results`
  (`Api::V1::App::JobTestResultsController`) returns every `TestRun`/`TestCase`
  ingested for a Job's most recent Workflow that has test data, grouped by
  grader and suite, each case annotated with its current flakiness score via
  `TestCase.batch_flakiness`.
- **Flaky badge on failing test cases** — `app/frontend/routes/JobDetail.tsx`
  (around line 1251) renders an amber "flaky" badge with a `failed/total`
  sparkline next to a failing test case's name when its `flakiness_score` is
  between 0 and 1 (i.e., it has both passed and failed recently) — a `0` or
  `1.0` score means it's either never failed or never passed and isn't
  flagged as flaky.
- **Global search** — test search results index `TestIdentity`, not
  `TestCase`, so repeated executions of the same test collapse into one
  result. Search results link directly to the repository Tests tab history
  page for that identity.

## Configuring this for another repository

1. Confirm the test runner can produce results in a format a registered
   `test_result_parser` understands — JUnit XML for the bundled core parser,
   or RSpec's native progress/documentation output for
   `SyrusRails::RspecParser` (accepting that the native route can't detect
   flakiness, per above).
2. Add whatever formatter/gem/flag the test runner needs to write that file
   (e.g. `rspec_junit_formatter`, `pytest --junitxml=...`, `jest --reporters
   default jest-junit`).
3. Set `junit_output: <path>` on every `.syrus.yml` grader entry that should
   ingest results. If the landing and CI phases use separate graders, both
   entries need their own `junit_output`.
