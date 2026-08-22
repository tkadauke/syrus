# Plugin Model And Component Moves

Syrus plugins are now real Rails engines, which means they can own routes,
controllers, assets, translations, jobs, models, and migrations. The next step
is to make the plugin boundary meaningful for durable data and code ownership,
without destabilizing the core workflow engine.

This plan is intentionally review-first. It describes the target conventions,
the likely extraction order, and the migration risks before we start moving
large pieces of code.

## Goals

- Keep core Syrus focused on cross-repo automation: jobs, workflows, runs,
  landing, dependencies, approvals, reconciliation, and generic plugin
  lifecycle.
- Move feature-specific durable state into the plugin that owns the feature.
- Make plugin install/enable/disable semantics clear:
  - Installed means code and migrations are present after restart.
  - Enabled means routes, UI, jobs, tools, and behavior are active.
  - Disabling a plugin hides/stops behavior but does not drop data.
- Keep plugin tables visually and mechanically obvious by prefixing table names
  with the plugin namespace.
- Avoid one-off extraction hacks. New plugins should be able to follow the same
  model, migration, route, asset, I18n, MCP, and admin-page conventions.

## Table And Model Convention

Plugin-owned Active Record models should be namespaced under the plugin module.
For a standard model, Rails already infers the desired table prefix:

```ruby
LinearSource::Ticket.table_name
# => "linear_source_tickets"
```

That is the convention we should require for plugin-owned tables:

- `SyrusDev::PerformanceLogEvent` -> `syrus_dev_performance_log_events`
- `AdminMysql::SlowQuerySnapshot` -> `admin_mysql_slow_query_snapshots`
- `Browser::VisualArtifact` -> `browser_visual_artifacts`

The exception is an extension model that intentionally shares a core table via
STI or another core extension point:

```ruby
InputSources::Github < InputSource
InputSources::Linear < InputSource
```

Those classes can share `input_sources` because the table is core-owned and the
plugin is only contributing a type/implementation. This exception should stay
explicit and rare.

We now have a grader that checks plugin model namespace/table-prefix hygiene.
That grader should be expanded as the convention gets stricter, especially once
plugin migrations are common.

## Migration Installation

Rails engines can ship migrations in `plugins/<plugin>/db/migrate`. The
standard Rails flow is:

```sh
bin/rails railties:install:migrations
bin/rails db:migrate
```

For Syrus, the important operational detail is that production deploys should
not generate new migration files at runtime. The release image should already
contain the copied migrations. A durable deploy flow should:

1. Install plugin migrations during development when adding/changing plugin
   schema.
2. Commit the copied app-level migrations.
3. In CI, verify that `railties:install:migrations` is clean, or at least that
   running it would not create uncommitted migrations.
4. In production, run normal `db:migrate` against the already packaged
   migrations.

This keeps deploys deterministic and keeps plugin enable/disable separate from
schema mutation.

## What Stays Core

These concepts should not move into plugins unless we later redesign the core
architecture:

- `Job`, `Epic`, `Workflow`, `Step`, `Run`
- job dependencies, approvals, landing queue, merge train, retry/reconcile
  logic, checkpoints, queue/admission primitives
- `Repository`, repository membership, app settings, feature gates
- plugin registry, plugin settings, plugin page/action/tool contribution APIs
- generic event/log/search infrastructure, even if concrete event tables move
  to plugins
- generic test insight models: `TestRun`, `TestCase`, `TestIdentity`

Core should define extension points. Plugins should implement concrete
integrations.

## Move Candidates

### `syrus_dev`

This plugin is specifically for developing and operating Syrus itself. It should
own Syrus-specific observability and development-only admin surfaces.

Move or finish moving:

- performance log storage and UI
- operational log storage, indexing, and UI
- browser error and backend exception admin search surfaces if we decide they
  are dev/observability features rather than core product features
- log/event pruning jobs for plugin-owned tables
- performance/admin MCP tools that only make sense while developing Syrus
- admin pages such as performance, operational logs, reconciler activity, and
  build cache if they remain Syrus-specific

Keep generic:

- the event ingestion API shape
- shared log-table UI components
- generic admin plugin page registration
- generic search/filter metadata conventions

Risk:

- Observability is used heavily to debug production. Disable behavior must be
  graceful: if `syrus_dev` is disabled, core pages must not hard-reference its
  tables or routes.

### `admin_mysql`

This plugin should own live MySQL inspection and any MySQL-specific durable
diagnostics.

Already appropriate:

- process list
- connection status
- statement digests
- slow log inspection
- kill-query action
- admin API and MCP tools for the same

Possible plugin-owned tables:

- `admin_mysql_slow_query_snapshots`
- `admin_mysql_process_samples`
- `admin_mysql_killed_queries`

Keep core:

- generic database support
- SQLite default behavior
- Rails app connection pool configuration

Risk:

- This plugin must stay disabled/hidden unless the active adapter is MySQL.
- Kill-query actions need audit logging, but the audit row should probably live
  in the plugin once durable audit tables exist.

### `build_cache`

Build cache management is another good plugin boundary. It is useful
operational infrastructure for Syrus deployments and language/toolchain builds,
but it is not part of the core issue-to-PR workflow model.

Move candidates:

- build cache admin page
- cache inspection API
- cache-clearing actions
- cache backend configuration and validation
- cache usage/size snapshots if we add durable history
- MCP/admin tools for reading cache state or clearing stale entries

Possible plugin-owned tables:

- `build_cache_snapshots`
- `build_cache_purge_events`
- `build_cache_backend_checks`

Keep core:

- generic plugin admin-page registration
- generic operational action auditing, if/when that becomes a shared service

Risk:

- Some deployments will not configure a shared build cache. The plugin should
  degrade to a clear "not configured" state and should probably be disabled by
  default unless a cache backend is configured.
- Cache purge actions can be expensive or destructive to build performance, so
  they should be audited and require explicit operator action.

### `browser`

This plugin should own browser automation and visual QA behavior.

Move candidates:

- visual review step implementation and prompt
- visual review artifacts and screenshot conventions
- preview/browser MCP glue
- browser-driven reviewer instructions and result rendering

Keep core:

- generic review-loop step shape
- generic preview lifecycle if previews remain useful outside browser QA
- generic artifact rendering extension point

Risk:

- Visual review currently participates in workflow chains. The workflow engine
  needs to ask plugins for optional steps without hardcoding browser behavior.

### `claude_agent` And `codex_agent`

Provider-specific behavior should continue moving out of core.

Move candidates:

- provider invocation classes
- transcript parsing
- provider-specific session resume details
- provider-specific usage/quota extraction and metadata parsing
- provider-specific settings UI
- provider-specific MCP/tool-name normalization where applicable

Keep core:

- generic agent provider interface
- `Run` agent metadata fields unless we introduce provider-specific side tables
- provider availability evidence if the product wants one global view across
  providers
- admission/pausing decisions based on generic provider availability

Risk:

- Provider quota bugs have repeatedly wedged the system. The shared provider
  circuit breaker must stay core and provider plugins should only contribute
  evidence/extractors.

### `github_source`

GitHub is currently deeply embedded. This is likely the largest and riskiest
future extraction.

Short-term move candidates:

- GitHub App admin UI
- GitHub polling jobs
- GitHub-specific PR review comment ingestion
- GitHub-specific auth fallback diagnostics
- source-control operations that are clearly GitHub API wrappers

Possible plugin-owned tables after a compatibility layer exists:

- `github_source_installations`
- `github_source_pr_review_comments`
- `github_source_auth_fallback_diagnostics`
- `github_source_external_events`

Keep core for now:

- `Repository` and `Job` GitHub-ish columns such as issue number, PR number,
  branch names, and mergeability state

Likely prerequisite:

- introduce generic source models such as `ExternalIssue`, `ExternalPullRequest`,
  `ExternalReviewComment`, or `SourceArtifact`
- migrate `Job` to reference generic source artifacts instead of assuming
  GitHub columns everywhere

Risk:

- Moving this too early will produce a fake plugin boundary. Keep GitHub
  source extraction incremental and schema-compatible.

### `linear_source`

Linear should own Linear-specific state once it becomes a real source plugin.

Move candidates:

- Linear API client and polling
- Linear-specific source mappings
- Linear issue metadata
- Linear admin/source settings

Acceptable shared-table pattern:

- `InputSources::Linear < InputSource` can share `input_sources` if input
  sources are core-owned extension points.

Future plugin-owned tables should use the plugin prefix:

- `linear_source_issues`
- `linear_source_workspace_mappings`

### Language And Framework Plugins

The generic test insight tables should stay core so the UI can compare tests
across languages and tools.

Move parser/augmentor behavior:

- `ruby`: RSpec/JUnit parsing, Ruby test command helpers
- `syrus_rails`: Rails-specific prepare detection, eager-load/migration/schema
  graders, Rails artifact renderers
- `javascript`: Vitest/Jest/Playwright parsing and Node prepare/build helpers
- `python`: pytest parsing and Python prepare helpers
- `go`: Go test parsing and Go prepare/build helpers
- `django`: Django-specific prepare/test/inspection helpers

Only add plugin-owned tables if the plugin needs durable metadata that does not
fit `TestRun`, `TestCase`, or `TestIdentity`.

Risk:

- Grader phases and test ingestion must remain understandable from `.syrus.yml`.
  Language plugins should contribute capabilities, not hide which checks run.

### Smaller Integration Plugins

For `discord`, `tailscale`, and similar integrations:

- keep core free of integration-specific tables
- add prefixed plugin-owned tables when durable state appears
- register admin pages/actions only when enabled
- make disable behavior stop side effects immediately but preserve data

## Admin UI And Assets

Plugins should be able to contribute:

- admin nav groups/pages
- route definitions
- JS entrypoints/components
- I18n strings
- MCP tools
- artifact renderers
- log-table sources/actions

Compiled JS does not need to disappear when a plugin is disabled. The registry
should decide whether a page/action is visible and callable. This keeps runtime
enable/disable simple and avoids rebuilding assets to toggle plugins.

## Search And Logs

The log/search UIs are converging on common metadata-driven components. That
pattern should apply to plugin-owned logs too:

- each log table declares searchable fields, sortable columns, detail panels,
  and row actions
- the shared admin UI synthesizes filters and sorting
- row actions such as "File Job" are declared by the table source, not
  special-cased per table

This lets future plugin event tables participate without copying bespoke UI.

## Implementation Order

### Phase 0: Lock Down Conventions

- Document plugin model/migration conventions.
- Keep the plugin model namespace/table-prefix grader in all grader phases.
- Add a migration-install cleanliness check once plugin migrations are common.
- Add examples for shared-core-table exceptions.

### Phase 1: Observability Into `syrus_dev`

- Move concrete performance and operational log models into `SyrusDev::`.
- Keep compatibility aliases while old code paths are migrated.
- Move prune/index jobs with the tables they own.
- Ensure disabling `syrus_dev` hides pages and stops jobs without crashing core.

### Phase 2: MySQL Diagnostics

- Keep live MySQL commands in `admin_mysql`.
- Add plugin-owned durable history only if it proves useful.
- Audit kill-query actions through a plugin-owned table or the shared log
  framework.

### Phase 3: Browser / Visual Review

- Move visual review prompt/step implementation into `browser`.
- Make workflow definitions ask enabled plugins for optional review loops.
- Move screenshot/result rendering into plugin contribution points.

### Phase 4: Provider Plugins

- Finish extracting Claude/Codex invocation and transcript parsing.
- Keep shared provider availability/circuit breaker core.
- Let provider plugins contribute evidence parsers and settings panels.

### Phase 5: Language Test Plugins

- Move parser/augmentor code into language/framework plugins.
- Keep generic `TestRun`/`TestCase`/`TestIdentity` core.
- Let plugins register test-result parsers and grader detail augmentors.

### Phase 6: Source Plugins

- First introduce generic source artifact abstractions.
- Then move GitHub-specific polling/API/admin code out of core.
- Avoid renaming core columns until the compatibility layer is proven.

## Open Questions

- Are browser/backend exception events core product diagnostics or
  `syrus_dev` observability?
- Should operational/performance logs be available when `syrus_dev` is disabled,
  or should disabling it mean "no dev observability UI/jobs"?
- Do plugin migrations get copied into the host app repository permanently, or
  do we eventually support loading migrations directly from installed plugin
  gems at release time?
- Which plugins, if any, are mandatory and not disableable?
- Do source plugins need a shared `ExternalArtifact` schema before more GitHub
  code moves, or can we move UI/poller code first?

## Non-Goals

- Do not move core workflow state into plugins.
- Do not make runtime enable/disable mutate schema.
- Do not create fake plugins that cannot actually be disabled.
- Do not rename large existing tables without compatibility aliases and a
  staged migration plan.
