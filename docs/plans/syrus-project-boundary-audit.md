# Syrus Project Boundary Audit

This is a planning audit for splitting this repository's workflow configuration
into project-aware `.syrus.yml` declarations. It intentionally does not move any
configuration.

## Current Boundaries

The repository is already a medium monorepo with these practical project
boundaries:

- **Core Rails app and SPA**: root Rails app, `app/`, `config/`, `db/`, `lib/`,
  root `package.json`, `vite.config.ts`, `tsconfig.json`, `spec/`, and shared
  scripts in `bin/`. This owns the production web app, worker process,
  workflow engine, MCP sidecar, shared React shell, design tokens, Rails
  migrations, and most operational checks.
- **Go CLI**: `cli/`, plus the root `go.work`. Several bundled plugins also
  contribute CLI modules through `plugins/*/cli`, so the CLI boundary is a Go
  workspace, not only the `cli/` directory.
- **Desktop app**: `desktop/`, with its own `package.json`, Vite config,
  Electron main/preload code, renderer, packaging scripts, and backend/CLI
  staging scripts. It depends on root assets and the Go CLI for release builds.
- **Public website**: `website/`, a separate Next.js/static-export app with its
  own lockfile and deploy workflow.
- **Plugins**: `plugins/*`, each with a gemspec and optional Rails app code,
  migrations, frontend, docs, e2e specs, and sometimes a Go CLI module. Most
  plugin changes still boot inside the core Rails host, so plugins are a
  workflow boundary before they are an independently previewable app boundary.
- **Release and infrastructure tooling**: `.github/workflows/`, `Dockerfile`,
  `docker-compose*.yml`, `install.sh`, `install.ps1`, `bin/release-*`,
  `bin/test-docker`, `e2e/`, and deployment docs. These cross product
  boundaries and should remain repo-level unless a later target graph models
  release artifacts explicitly.
- **Future mobile**: no mobile project exists today. The target-graph docs
  already describe iOS and Android as separate future projects. A future mobile
  shell should be introduced as its own nested project, most likely
  `mobile/.syrus.yml` for a shared cross-platform app or separate
  `ios/.syrus.yml` and `android/.syrus.yml` if native platforms diverge.

## Existing Workflow Primitives

Root `.syrus.yml` currently declares:

- `prepare`: `bundle config set --local path vendor/bundle`, `bundle install`,
  and root `npm ci`.
- `preview`: root Rails/Vite/Tailwind preview through `bin/syrus-preview-dev`,
  with `bin/rails db:prepare db:seed`, `/up`, development logs, preview search
  database env, and DB env cleanup.
- `visual_review`: enabled, two rounds, scoped to `app/frontend`, `app/views`,
  `plugins/**/app/frontend`, and `plugins/**/app/views`, with seed notes for
  the demo preview state.
- `hooks.post_checkout`: root bundle check/install, `rails db:migrate`, then
  discard local schema/structure churn.
- `adversarial_review`: one round with repo-wide criteria around docs,
  specs, duplication, type-switch avoidance, user attribution, feature flags,
  and frontend locale parity.
- `grade`: 17 graders:
  `migration-collisions`, `migration-lint`, `migration-baselines`,
  `thread-budget`, `feature-slugs`, `plugin-model-namespaces`,
  `plugin-boundaries`, `eager-load`, `work-engine-simulations`,
  `production-build-boot`, `cli-go-tests`, `rspec`, `rspec-focused`,
  `rspec-ci`, `react-tests`, `react-tests-focused`, and `website-build`.
- `coverage`: LCOV sources at `coverage/lcov.info` and `coverage/js/lcov.info`,
  line threshold 70, `on_miss: warn`, PR comments enabled, seven-day hitmap TTL.
- `deployment_stages`: staging, production, and public tag tracking.

Root `.syrus.yml` does **not** currently declare `formatters:`, `generated:`,
`deploy:`, `review_plan:`, `delivery:`, `approval:`, `external_prs:`,
`agent_insight:`, explicit `project:`, explicit `targets:`, or
`target_graph.imports`.

## Repo-Wide Checks

These should remain rooted at `/.syrus.yml` because they validate repository
invariants or cross-boundary release safety:

- `migration-collisions`: scans all migration namespaces, including plugin
  migrations.
- `migration-baselines`: verifies primary database history against deployment
  baselines; this is a release safety check, not a single project check.
- `thread-budget`: protects the production worker/database connection budget.
- `feature-slugs`: shared feature declarations are consumed by Rails and the
  SPA across projects.
- `plugin-boundaries`: checks core-to-plugin and plugin-to-plugin dependency
  policy across the whole plugin ecosystem.
- `eager-load`: Rails production boot/constant loading spans core and enabled
  plugin code.
- `work-engine-simulations`: validates central workflow scheduling behavior.
- `production-build-boot`: validates Rails production boot during image build.
- `rspec` and `rspec-ci`: keep as landing/CI backstops until narrower
  project-specific Ruby graders have enough coverage history.
- `deployment_stages`: stage tracking is currently repository-wide by design.

## Project-Owned Checks

These are good candidates for nested project declarations:

- `website-build`: belongs in `website/.syrus.yml`.
- Desktop typecheck, renderer build, main-process build, and staging smoke
  checks: belong in `desktop/.syrus.yml`. The current root config only covers
  desktop indirectly through `react-tests-focused` and `cli-go-tests`.
- CLI Go tests: should be split between `cli/.syrus.yml` for the core CLI and
  `plugins/.syrus.yml` or plugin-specific configs for plugin CLI modules.
  A repo-level Go workspace check can remain as a landing backstop while that
  split proves out.
- `react-tests-focused`: should become project-aware across core frontend,
  plugin frontend, and desktop renderer paths instead of one broad root
  selector.
- `rspec-focused`: can stay root-owned for core Rails paths while plugin Ruby
  specs gain plugin-scoped targets.
- `plugin-model-namespaces`: belongs to the plugin project boundary, but still
  needs visibility into host/plugin model loading. Treat it as a plugin-owned
  Rails-host check, not an isolated gem check.
- `migration-lint`: can be file-scoped to root and plugin migration paths; the
  command itself remains root-relative because migration policy is shared.

## Migration Plan

### 1. Add Explicit Root Metadata

Keep `/.syrus.yml` as the root repository project and add only metadata first:

```yaml
project:
  label: Repository
  kind: rails_app
```

Expected behavior: no grader or prepare behavior changes. Existing root
targets still compile under `//:repo`, and all repo-wide checks keep their
legacy affected-target behavior.

### 2. Move Website Workflow To `website/.syrus.yml`

Create `website/.syrus.yml`:

```yaml
project:
  id: website
  label: Public Website
  kind: website

prepare:
  - npm ci

grade:
  - name: build
    run: npm run sync-release:check && npm run build
    phases: [landing, ci]
    failures: allow_inherited
    base_retry:
      strategy: full_command
    timeout_minutes: 10
```

Remove `website-build` from the root file only after verifying equivalent
selection. Expected behavior: website-only diffs select `//website:grade/build`
instead of a root grader; unrelated app, CLI, and desktop diffs skip the website
build unless they touch shared release/deploy files that still have a repo-level
dependency.

### 3. Add Desktop Project Config

Create `desktop/.syrus.yml`:

```yaml
project:
  id: desktop
  label: Desktop App
  kind: desktop_app

prepare:
  - npm ci
  - npm --prefix .. ci

grade:
  - name: typecheck
    run: npm run typecheck
    phases: [review, landing, ci]
    when_files_changed: ["src/**", "electron/**", "scripts/**", "package*.json", "tsconfig*.json"]
  - name: renderer-build
    run: npm run build:renderer
    phases: [landing, ci]
    when_files_changed: ["src/**", "vite.config.ts", "package*.json"]
  - name: main-build
    run: npm run build:main
    phases: [landing, ci]
    when_files_changed: ["electron/**", "tsconfig.electron.json", "package*.json"]
  - name: stage-backend
    run: npm run stage:backend
    phases: [landing, ci]
    when_files_changed: ["scripts/stage-backend-assets.mjs", "electron/**"]
```

Expected behavior: desktop diffs select desktop targets and root shared checks.
CLI packaging paths such as `desktop/scripts/stage-cli.mjs` should keep a
dependency on the CLI Go workspace check until explicit target dependencies
model the staged CLI artifact.

### 4. Split CLI And Plugin CLI Checks

Create `cli/.syrus.yml`:

```yaml
project:
  id: cli
  label: CLI
  kind: cli

prepare:
  - mise exec go@1.26.5 -- go mod download

grade:
  - name: go-tests
    run: mise exec go@1.26.5 -- go test ./...
    phases: [review, landing, ci]
```

Create `plugins/.syrus.yml` with a plugin ecosystem project:

```yaml
project:
  id: plugins
  label: Plugins
  kind: plugin_collection

grade:
  - name: cli-go-tests
    run: cd .. && mise exec go@1.26.5 -- sh -c 'go test $(go list -m -f "{{.Dir}}/..." | grep "/plugins/")'
    phases: [review, landing, ci]
    when_files_changed: ["*/cli/**/*.go", "*/cli/go.mod"]
```

Expected behavior: core CLI diffs select `//cli:grade/go-tests`; plugin CLI
diffs select `//plugins:grade/cli-go-tests`; release workflow and desktop
packaging diffs keep selecting a repo-level backstop until explicit deps wire
those paths to CLI targets.

### 5. Split Plugin Rails/Frontend Checks Carefully

Start with one `plugins/.syrus.yml`, not one file per plugin. Most plugins are
not independently previewable; they run inside the Rails host and share the
same boot, schema, and frontend build surfaces.

Candidate plugin-owned targets:

```yaml
grade:
  - name: rspec-focused
    run: cd .. && BUNDLE_PATH="$PWD/vendor/bundle" BUNDLE_APP_CONFIG="$PWD/.bundle" bin/rspec-focused
    phases: [review]
    when_files_changed: ["**/*.rb"]
  - name: react-tests-focused
    run: cd .. && bin/test-react-focused
    phases: [review]
    when_files_changed: ["*/app/frontend/**/*.ts", "*/app/frontend/**/*.tsx"]
  - name: model-namespaces
    run: cd .. && BUNDLE_PATH="$PWD/vendor/bundle" BUNDLE_APP_CONFIG="$PWD/.bundle" bin/check-plugin-model-namespaces
    phases: [review, landing, ci]
    when_files_changed: ["*/app/models/**/*.rb", "*/db/migrate/**/*.rb"]
```

Expected behavior: plugin diffs select plugin-focused review checks plus the
repo-wide Rails boot and boundary checks. A plugin that later gets its own
preview, coverage policy, or substantially independent app surface can graduate
to `plugins/<name>/.syrus.yml`.

### 6. Keep Core Rails/SPA Root-Owned Initially

Do not create separate `app/.syrus.yml`, `app/frontend/.syrus.yml`, or
`db/.syrus.yml` in the first split. The Rails app, worker, core frontend, and
database are one product boundary today. Use root target scopes instead:

- root `rspec-focused`: `app/**/*.rb`, `lib/**/*.rb`, `spec/**/*.rb`;
- root `react-tests-focused`: `app/frontend/**/*.ts(x)`;
- root migration checks: `db/migrate/**`, `plugins/*/db/migrate/**`;
- root preview and visual review: continue to cover core and plugin UI.

Expected behavior: app/backend and app/frontend diffs continue to behave
mostly like today, but website/desktop/CLI-only diffs stop paying for unrelated
project checks once their nested configs are active.

### 7. Add Future Mobile As A New Project

When mobile code lands, create either:

- `mobile/.syrus.yml` for one cross-platform project, or
- `ios/.syrus.yml` and `android/.syrus.yml` for native platform projects.

Expected behavior: mobile-only diffs select only mobile prepare/grade targets
plus repo-wide safety checks. API contract dependencies should be modeled with
explicit `targets:` labels, for example a root API-contract target depended on
by mobile test targets.

## Open Questions Before Moving Config

- Should root preview remain the fallback for plugin UI changes after a
  `plugins/.syrus.yml` project exists, or should plugin UI changes explicitly
  depend on a root preview target once preview selection supports that shape?
- Should the Go workspace check remain one repo-level target permanently
  because `go.work` intentionally models CLI plus plugin CLI modules together,
  or should nested CLI checks become authoritative after a trial period?
- Should full `rspec` and `react-tests` stay root landing backstops even after
  focused review checks become project-scoped? For now, yes; removing them is a
  later coverage-confidence decision, not part of the first config move.
- Should release/test-build workflow paths select desktop, CLI, backend image,
  and website targets explicitly through `targets:` dependencies rather than
  broad `when_files_changed` globs? That is likely the right second pass.
