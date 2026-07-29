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
| `description` | no | — | Human-readable label |
| `required` | no | `true` | Non-required failures warn but don't block |
| `timeout_minutes` | no | 15 | Clamped to 30 max |
| `when_files_changed` | no | — | Array of glob patterns; grader is skipped at fanout time if none of the PR's changed files match |

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


## reconciliation_mode

Controls whether Syrus creates a reconciliation Job when an Epic goes `in_progress` with two or more child Jobs.

```yaml
reconciliation_mode: pr      # create reconciliation Job before landing (default)
reconciliation_mode: none    # skip reconciliation; siblings land independently
```

Valid values: `pr`, `none`. Omitting the key defaults to `pr`.

The reconciliation Job is a `kind=direct` Job that depends on all sibling Jobs in the Epic and runs a cross-cutting review before siblings are allowed to land. See the `reconciliation.md` operator doc for full details.

An Epic-level `reconciliation_mode` column takes precedence over this `.syrus.yml` setting.
