# .syrus.yml Reference

The `.syrus.yml` file at the root of a repository configures how Syrus prepares the workspace, runs graders, and handles optional features like adversarial review and coverage reporting.

## prepare

Shell commands Syrus runs before handing off to the agent. Each command runs in the cloned workspace in order.

```yaml
prepare:
  - bundle install
  - npm ci
```

Use `prepare: []` or `prepare: false` to opt out entirely. If `.syrus.yml` is absent, Syrus auto-detects a single setup command from lockfiles in this priority order: `Gemfile` → `yarn.lock` → `pnpm-lock.yaml` → `package-lock.json` → `package.json`. Auto-detected commands soft-fail (warning + agent still runs); explicit `.syrus.yml` commands hard-fail and abort the chain.

Set `Repository#prepare_enabled` to false in the admin UI to disable the prepare step for all workflows on a repo. Add the `syrus-skip-prepare` label to an issue to skip it for that Job only.

## hooks.post_checkout

Commands run by the `syrus checkout` CLI on the operator's local machine after checking out a branch. These do **not** run in the agent sandbox.

```yaml
hooks:
  post_checkout:
    - bin/setup-local
```

## grade

Graders are shell commands Syrus runs to validate the agent's work. All graders must pass before the workflow succeeds.

```yaml
grade:
  max_iterations: 5
  steps:
    - name: rspec
      run: bin/rspec
      fast: COVERAGE=false bin/rspec-fast
      ci: COVERAGE=false bin/rspec-ci
      description: Run the Ruby test suite
      required: true
      timeout_minutes: 15
    - name: typecheck
      run: npm run typecheck
      required: false
      timeout_minutes: 10
    - name: website-build
      run: npm --prefix website run build
      when_files_changed:
        - "website/**"
        - "docs/**"
```

The short form (array) uses instance-wide `AppSetting.grade_max_iterations`:

```yaml
grade:
  - name: rspec
    run: bin/rspec
```

### grade step fields

| Field | Required | Default | Notes |
|---|---|---|---|
| `name` | yes | — | Alphanumeric + hyphens; must be unique |
| `run` | yes | — | Shell command |
| `fast` | no | — | Alternate shell command for pass/fail-only validation contexts |
| `ci` | no | — | Alternate shell command for `ci_failure` workflows |
| `description` | no | — | Human-readable label |
| `required` | no | `true` | Non-required failures warn but don't block |
| `timeout_minutes` | no | 15 | Clamped to 30 max |
| `when_files_changed` | no | — | Array of glob patterns; grader is skipped at fanout time if none of the PR's changed files match |

### fast

`fast` is an optional alternate command for the same grader. Syrus uses it when the grader result is only a pass/fail safety check and no fresh coverage report is consumed: `main_branch_repair`, `auto_merge`, `merge_train`, and implementation/feedback/coding grade-loop iterations after the first. `main_grader` uses `ci` when present, otherwise `fast`, otherwise `run`. If `fast` is absent in a fast context, Syrus falls back to `run`.

For Ruby projects, prefer putting formatter, coverage, parallelization, and CI-only filtering policy in a wrapper script such as `bin/rspec-fast`. Grader infrastructure should run the configured command as-is instead of appending RSpec-specific flags.

For example, a Ruby suite can keep coverage on for the first implementation validation while disabling coverage instrumentation for landing and repair rechecks:

```yaml
grade:
  - name: rspec
    run: bin/rspec
    fast: COVERAGE=false bin/rspec-fast
```

### ci

`ci` is an optional alternate command for `ci_failure` workflows. Use it when the CI-only checks are too expensive for normal Syrus grading, but must run when Syrus is specifically repairing a failed CI check. If `ci` is absent, Syrus falls back to `run`; it never falls back from `ci` to `fast`.

```yaml
grade:
  - name: rspec
    run: bin/rspec
    fast: COVERAGE=false bin/rspec-fast
    ci: COVERAGE=false bin/rspec-ci
```

Use CI-only specs for checks that are too slow, too environmental, or too broad for the normal Syrus grader loop but still important in GitHub Actions. They should run during `ci_failure` workflows so the agent can verify that a CI failure is actually fixed. Main-grader workflows also use `ci` when present so main-branch health reflects the GitHub CI suite. Normal implementation, feedback, and landing workflows should use `run` or `fast`, not the CI-only command.

### Recommended test setup

For repositories with meaningful test suites, prefer small wrapper scripts over long inline grader commands. Put test-runner-specific policy in the repository, not in Syrus:

- formatter setup (for example, progress on stdout plus JSON or JUnit artifacts)
- coverage toggles and artifact paths
- parallelization and per-worker result files
- exclusion of CI-only tests from the normal fast suite

A good default shape is:

```yaml
grade:
  - name: tests
    run: bin/test-with-coverage
    fast: bin/test-fast
    ci: bin/test-ci
```

Use `run` for the normal validation command. If coverage reporting is configured, this is usually the command that produces coverage artifacts. Use `fast` for pass/fail-only rechecks where fresh coverage is not consumed, such as landing, repair checks, and repeat grade-loop iterations. Use `ci` for CI-failure repair workflows and main-branch grading, where Syrus needs to run the slower checks that GitHub Actions ran.

Keep the normal grader suite fast enough for repeated agent use. A useful target is under 30 seconds for the primary pass/fail suite. If tests are slow because they create real repositories, spawn shells, hit network services, exercise large filesystem trees, or boot full integrations, first try to replace that cost with fakes, dependency injection, fixtures, or narrower unit coverage. Mark tests CI-only only when the real integration behavior is important and cannot reasonably be made fast.

### when_files_changed

`when_files_changed` is an optional array of glob strings on any grader step. When set, Syrus computes the PR's changed files via `git diff --name-only <base>...HEAD` at fanout time and skips the grader if none of the changed files match any of the supplied patterns. An absent or empty list means the grader always runs.

```yaml
grade:
  - name: website-build
    run: npm --prefix website run build
    when_files_changed:
      - "website/**"
      - "docs/**"
  - name: rspec
    run: bin/rspec
    # no when_files_changed → always runs
```

Glob matching uses `File::FNM_DOTMATCH` so `*` and `**` cross directory separators — `website/**` matches any file under the `website/` directory at any depth, including dotfiles. If the git diff command fails (e.g. no commits on the branch yet), Syrus logs a warning, treats the changed-file list as empty, and skips any grader with `when_files_changed` set while still running graders without it.

### grade.max_iterations

How many repair→check cycles Syrus attempts before failing the workflow. Range: 1–10. Defaults to `AppSetting.grade_max_iterations` (instance-wide default: 5).

## adversarial_review

Enables an independent reviewer agent that critiques the implementation before graders run.

```yaml
adversarial_review:
  rounds: 2
  criteria:
    - Verify all new endpoints enforce authentication
    - Check that database queries use parameterized inputs
```

`rounds` controls how many implement→review iterations run. Range: 0–10. Rounds set here override the instance-wide `AppSetting.adversarial_review_rounds`. Set to `0` to disable.

`criteria` is an optional array of strings directing the reviewer toward repository-specific concerns. When present, each entry is included as a focus area in the reviewer prompt, supplementing the standard review checklist. Omitting `criteria` or supplying an empty array keeps existing behaviour. Blank entries are silently dropped.

## visual_review

Configures the visual_review Labs feature: a headless-browser QA pass the worker agent runs against its own in-step preview to catch visible defects and capture screenshot artifacts.

```yaml
visual_review:
  enabled: true
  rounds: 2
  when_files_changed:
    - "app/frontend/**/*"
    - "app/views/**/*"
  seed_notes: "Log in as demo@example.com / password to reach the dashboard."
```

`enabled` turns visual review on for this repository. Defaults to `false`; when the block (or the `enabled` key) is omitted, the instance-wide `AppSetting.visual_review_enabled?` default applies.

`rounds` controls how many visual-review passes run. Range: 0–10, defaults to `1`.

`when_files_changed` is an optional array of glob patterns; when present, visual review only runs when at least one changed file (relative to the default branch) matches one of the patterns. Uses the same glob semantics as a grader's `when_files_changed`. Omitting it runs visual review regardless of which files changed.

`seed_notes` is optional free text describing how to reach an authenticated or otherwise populated state in the preview app (e.g. demo credentials, a seed record to look for). It is read by the visual_review agent as a hint, not executed.

## coverage

Enables coverage reporting. Syrus parses lcov or Cobertura artifacts produced by graders, computes diff annotations, and optionally posts a PR comment.

```yaml
coverage:
  sources:
    - artifact: coverage/lcov.info
      format: lcov
    - artifact: coverage/cobertura.xml
      format: cobertura
  threshold:
    lines: 80
    pr_lines: 70
  on_miss: warn
  pr_comment: true
  hitmap_ttl_days: 7
```

### coverage fields

| Field | Required | Default | Notes |
|---|---|---|---|
| `sources` | yes | — | Array of artifact paths + format |
| `threshold.lines` | no | — | Overall line coverage % (0–100) |
| `threshold.pr_lines` | no | — | PR-diff line coverage % (0–100) |
| `on_miss` | no | `warn` | `block`, `warn`, or `schedule` |
| `pr_comment` | no | `false` | Post coverage summary as PR comment |
| `hitmap_ttl_days` | no | 7 | Days to retain the hit-map blob |

`on_miss` behaviors: `block` fails the workflow, `warn` logs a warning and continues, `schedule` triggers a follow-up coverage-fix Job.

## deployment_stages

Configures the named deployment pipeline stages Syrus will track for this repository. Each stage maps to a git tag (or tag pattern) that advances as the merge commit propagates through your deployment pipeline.

```yaml
deployment_stages:
  - name: staging
    label: "On Staging"
    tag: staging
  - name: production
    label: "In Production"
    tag: production
  - name: public
    label: "Released to Public"
    tag: release
  - name: canary
    label: "Canary"
    tag_pattern: "deploy-canary-*"
```

Omitting `deployment_stages` or supplying an empty array disables stage tracking for the repository.

### deployment_stages fields

| Field | Required | Default | Notes |
|---|---|---|---|
| `name` | yes | — | Alphanumeric characters and underscores only; must be unique within the list |
| `label` | no | Titleized `name` | Display label shown in the UI |
| `tag` | yes (or `tag_pattern`) | — | Exact git tag name (typically a moving tag) |
| `tag_pattern` | yes (or `tag`) | — | Glob pattern; Syrus finds the latest matching tag |

Each stage must specify exactly one of `tag` or `tag_pattern` — not both.

**`tag`** is for a single moving tag that your deployment pipeline advances (e.g. `staging` or `production`). Syrus checks whether the job's `landed_sha` is an ancestor of that tag's commit.

**`tag_pattern`** is a glob pattern (e.g. `deploy-staging-*`) when your pipeline pushes a new dated tag on each deploy. Syrus finds the most recent tag that matches and checks ancestry.

`PollAllDeploymentStagesJob` runs every 5 minutes and fans out to repositories with `deployment_stages` configured. For each landed Job (`landed_sha` present), Syrus compares the merge commit against each configured stage tag. When GitHub reports the tag as `identical` to or `ahead` of the merge commit, Syrus records a `JobDeploymentStageStatus` with the first detected time and the tag commit SHA for audit/debugging.

Configured stages are shown on Job detail pages and as per-stage columns in the Epic detail jobs table. Epic rows show a reached timestamp for landed Jobs that have reached a stage, a pending marker for landed Jobs still waiting on a stage, and an empty marker for Jobs that have not landed yet.
