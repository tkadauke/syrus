# Release Notes

## Unreleased

- Added project-aware monorepo configuration. Existing root-only
  `.syrus.yml` files keep their current behavior, while repositories can now
  opt into explicit project boundaries with nested `.syrus.yml` files, shared
  target declarations, and imported build-system graphs. Syrus never infers a
  project from directory layout alone; a project boundary exists only when the
  repository declares it.
- Project-aware adoption is staged. Start with the root config, then add
  nested project files for apps or products that need their own preview,
  visual review, adversarial-review criteria, coverage policy, or checkout
  hook. Keep critical review, landing, and CI validation in the root `grade:`
  plan while nested graders are used as target-graph declarations and
  dependency-analysis hints.
- Target graph selection now gives operators clearer explanations for why a
  root grader ran, skipped, or reused a healthy target proof. Grader
  `deps:` edges can point at explicit targets, and materialized graders run
  transitive `kind: prepare` target dependencies at most once per workflow
  workspace.
- Job previews and visual review can select affected preview-capable projects
  from nested `preview:` blocks. A single affected preview starts directly,
  multiple affected previews show a project choice, and unrelated project
  previews are not started when the diff does not touch them.
- Coverage can be declared per project. Nested coverage artifact paths are
  resolved from the nested `.syrus.yml` directory, project thresholds are
  reported separately, and repository summaries remain compatible with
  root-only coverage.
- Migration checklist for root-only grader configs:
  1. Leave the existing root `.syrus.yml` in place and confirm the current
     root `prepare:`, `grade:`, `coverage:`, and `preview:` behavior is still
     the source of truth.
  2. Add nested `.syrus.yml` files only for real operator-facing project
     boundaries such as `apps/web`, `apps/mobile`, `desktop`, or `cli`.
  3. Move project-specific `preview:`, `visual_review:`, coverage sources,
     adversarial-review criteria, and `hooks.post_checkout` into those nested
     files.
  4. Add nested `grade:` entries to document project checks in the target
     graph, but keep executable protection in root graders such as
     `npm --prefix apps/web run typecheck` until nested-grader execution
     policy lands.
  5. Add explicit `targets:` only when reusable source scopes or dependency
     edges make selection, caching, or operator explanations clearer.
  6. Inspect the target graph UI/API after each stage and fix missing
     `sources`, `when_files_changed`, or `deps:` declarations before removing
     any root coverage.
- Before/after example:

  ```yaml
  # Before: /.syrus.yml
  prepare:
    - npm ci

  grade:
    - name: web-typecheck
      run: npm --prefix apps/web run typecheck
      when_files_changed: ["apps/web/**"]
    - name: cli-tests
      run: go test ./cli/...
      when_files_changed: ["cli/**"]
  ```

  ```yaml
  # After: /.syrus.yml
  prepare:
    - npm ci

  grade:
    - name: web-typecheck
      run: npm --prefix apps/web run typecheck
      when_files_changed: ["apps/web/**"]
    - name: cli-tests
      run: go test ./cli/...
      when_files_changed: ["cli/**"]
  ```

  ```yaml
  # After: apps/web/.syrus.yml
  project:
    id: web
    label: Web App
    kind: web_app

  preview:
    setup:
      - npm ci
    start: npm run dev -- --host 0.0.0.0 --port $PORT
    health_check: /

  coverage:
    sources:
      - artifact: coverage/lcov.info
        format: lcov

  grade:
    # Graph declaration for project-aware selection and diagnostics. Keep the
    # executable root grader above until nested grader execution lands.
    - name: typecheck
      run: npm run typecheck
      when_files_changed: ["src/**/*.ts", "src/**/*.tsx"]
  ```
- Known limitations remain deliberately explicit. Nested `formatters:`,
  `generated:`, `grade:`, and explicit executable targets compile into the
  graph before every workflow path can materialize them directly. Root
  `deploy:` is still the repository-level deployment command, and
  `deployment_stages:` are repository-scoped in this release; nested
  deployment stages and project-scoped deployment workflows remain open design
  questions.
  See `config/syrus_docs/monorepo_adoption.md` for the full staged adoption
  guide.
- Removed the MVP operator-interrupt path and external chat delivery support.
  Agent runs now proceed or fail without parking in an operator-chat state.
- Documentation now describes the cleaned-up MVP surface: polling-driven
  GitHub automation, scheduled tasks, trusted-user/trusted-repo sandbox
  assumptions, force-with-lease rebase pushes, hourly scheduled-task
  semantics, and credential/API-token revoke controls.
- Removed stale current-doc references to deleted non-MVP surfaces:
  inbound delivery handlers, captured-session continuation, human
  escalation, shared drawing surfaces, and native GitHub suggestion
  application.
