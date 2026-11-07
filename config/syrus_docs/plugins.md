# Plugins

Plugins add optional capabilities to Syrus without making every installation
pay their runtime cost. A plugin can contribute agent and chat providers, MCP
tools, input and source-control integrations, previews, graders and review
helpers, repository content, execution backends, workspace tabs, admin or
repository pages, search sources, scheduled work, and other focused product
features.

The complete installed inventory is available under **Admin → Plugins**. Plugin
authors should use the [engineering authoring reference](../../docs/engineering/conventions/plugins/authoring.md); this page describes behavior that operators and agents need when using plugins.

## Per-origin Job visibility

Repository membership remains the outer visibility boundary for Jobs. A plugin
may further restrict only Jobs created by that plugin's own origin. Core lists,
searches, counts, detail pages, and related Workflow or Run lookups honor that
restriction. Jobs from origins without a restriction keep normal repository
visibility, and global admins bypass origin restrictions.

Disabling or uninstalling the plugin removes its restriction. A plugin that
stores sensitive output must therefore clean up its Jobs or retain another
protection before it is disabled.

## Inventory, installation, and enablement

**Admin → Plugins** shows each installed plugin's name, version, enabled state,
category, description, dependency health, registered capabilities, usage
blockers, documentation, configuration, metrics, and operator links. The
inventory can be filtered by enabled state, author, extension point,
experimental status, category, or text. It intentionally has no saved
SmartFolders.

Installation and enablement are separate:

- **Installed** means the plugin gem is in the application bundle and the
  application has restarted. Its code, routes, frontend modules, translations,
  and migrations are present.
- **Enabled** means its runtime capabilities and product surfaces are available.
  Disableable plugins can be toggled from their inventory card or detail page.
- **Experimental** plugins also require instance beta mode. Beta mode only
  permits enablement; it never enables a plugin automatically.

New installations leave agent-provider plugins, Build Cache, Design Docs,
Spending Insights, Team Directory, Credential Store, and Git History disabled.
Credential Store and Git History are also experimental. Existing installations
keep their explicit enablement choices when defaults change.

### What a disabled plugin costs

Disabled plugin code is not eagerly loaded, although it remains available for
on-demand loading so enablement does not require a restart. Plugin migrations
always run during deployment regardless of enabled state; runtime toggles never
run migrations.

| Plugin state | Enabled-only effects | Cleanup effects | Eager loaded |
| --- | --- | --- | --- |
| Enabled | yes | yes | yes |
| Disabled, previously enabled here | no | yes | no |
| Never enabled here | no | no | no |

Cleanup effects remain active after disablement so records already created by a
plugin are not orphaned. A plugin that has never been enabled has no such data.

### Telling an admin a plugin exists

A disabled plugin may recommend itself when Syrus has concrete local evidence
that it would help, such as detected repository technology, configured database
adapters, worker hosts, recent agent activity, repository count, or Syrus
repositories. Recommendations are informational only, never gate work, and are
suppressed when there is no evidence or the plugin is already enabled.

## Where plugin documentation lives

A plugin's full documentation lives under its own
`plugins/<name>/docs/syrus_docs/` directory. Removing the plugin therefore
removes its documentation too.

`search_syrus_docs` builds its corpus from core searchable documentation, every
enabled plugin's documentation, and a short generated teaser for each installed
but disabled plugin. The teaser explains that the capability is disabled and
how to enable it. Searching for the plugin by name boosts that teaser.

## Plugin categories

| Category | Purpose |
| --- | --- |
| Language & framework intelligence | Repository setup, review, tests, and ecosystem tools |
| Agent provider | Workflow and chat agent backends |
| Agent capability | Tools that expand what agents can do |
| Input source | Sources that create or update work |
| Platform delivery | External delivery channels |
| Connectivity | Network and hosting integrations |
| Observability | Operational and engineering insight surfaces |
| Collaboration | Shared search, documents, directories, and planning |
| Tooling | Optional operator and execution tools |

A category describes what a plugin is for, not which extension points it uses.

## Plugin dependencies and health

Plugins may declare hard dependencies, optional dependencies, and conflicts.

| Relationship | Behavior |
| --- | --- |
| `depends_on` | The dependency must be installed and enabled; enabling cascades to it. |
| `optionally_depends_on` | Extra behavior is available when the dependency is enabled. |
| `conflicts_with` | The two plugins cannot be enabled together. |

An enabled plugin is `degraded` when a hard dependency is missing or disabled,
or when an enabled conflict exists. A dependency cycle reports `cycle` for all
participants. Degraded and cyclic plugins keep their data and settings but
withhold their runtime capabilities; they do not prevent Syrus from booting.

Enablement can cascade through hard dependencies. Disabling a dependency can
cascade through its enabled dependents, but the admin must confirm the complete
set first. Disablement is rejected with a `plugin_in_use` HTTP 409 response when
active records or another runtime blocker still use the plugin.

## Plugin lifecycle

| Operation | Runtime behavior | Data |
| --- | --- | --- |
| Disable | Capabilities withheld, UI hidden, work skipped, routes report `plugin_disabled` | retained |
| Uninstall | Gem removed and no longer registered after restart | retained |
| Purge | Plugin-owned tables and contributed external resources removed | destroyed |

Installation and uninstallation are manual: update the bundle, run migrations,
rebuild frontend assets when needed, and restart application processes. Purge is
an explicit, destructive operation performed only after uninstalling:

```sh
bin/rails 'plugin:data[build_cache]'    # preview what purge removes
bin/rails 'plugin:purge[build_cache]'   # confirm and destroy plugin data
```

## Repository workflow behavior contributed by plugins

### Post-implementation review and adjudication

Post-implementation review is best-effort. A provider failure does not discard
the implementation; the step can be retried or skipped. When a grader failure
needs adjudication, Syrus asks enabled adjudicators in order. Repositories may
opt into known-flaky dismissal with
`known_flaky_failure_dismissal_enabled` and isolated-reproduction dismissal
with `isolated_repro_dismissal_enabled`.

### Grader types and retries

A grader may set `grader_type` to `type: rspec` to receive structured RSpec handling. Its
`fixed_full_path` identifies an exact test command, while `paths` and `phases`
describe selectable files and phases. A `base_retry` strategy controls how a
focused retry is formed:

- `plugin` delegates retry construction to the supporting plugin;
- `files_as_args` appends selected files to the base command;
- `full_command` runs the configured retry command unchanged.

### Prepare detection

When `.syrus.yml` has no explicit `prepare:`, each enabled `prepare_detector`
plugin inspects the repository and contributes setup commands. Typical
detections include Ruby
Bundler, JavaScript package managers, Python uv/Poetry/pip, Go modules, and JVM
Gradle or Maven wrappers. Commands run in priority order and identical commands
are deduplicated. Detected version files may cause the matching toolchain to be
installed through mise before setup. `prepare: []` or `prepare: false` opts out.

### Autofix, audits, affected tests, and review criteria

`autofix_command` lets ecosystems contribute formatters or safe autofixes.
Setting `formatters: []` opts into all applicable plugin defaults; an autofix
failure is reported but does not fail implementation. `dependency_audit_command`
adds ecosystem vulnerability checks. `affected_test_analyzer` expands changed
files into likely affected tests. `review_criteria_provider` seeds relevant
repository review criteria without overriding repository configuration.

### Build-system imports

A `build_system_graph_provider` may import targets into `target_graph.imports`:

```yaml
target_graph:
  imports:
    - provider: example
      failures: strict # or warn
      config: {}
```

`strict` makes import failure fatal; `warn` reports the failure and continues.
Provider-specific settings belong under `config`.

### Execution backends

An `execution_backend` may accept work through the shared execution contract.
The bundled Container Execution backend accepts a grader only when
the plugin is enabled, an image is configured or resolved, Docker is reachable,
and every requested mount maps from the worker to the Docker host. If any
condition is unmet, execution falls back to the local backend unless workload
policy requires fail-closed execution.

## Runtime session tools

Runtime-capable plugins expose these tools in Coding Mode:

`runtime_list_providers`, `runtime_list_sessions`, `runtime_start`,
`runtime_stop`, `runtime_inspect`, `runtime_input`, `runtime_wait`,
`runtime_snapshot`, `runtime_capture_artifact`, `runtime_build`,
`runtime_get_capabilities`, `runtime_acquire_control`, and
`runtime_release_control`.

They are gated by the `coding_mode` flag. Tools that send keyboard, stdin,
pointer, or resize input require a current control lease obtained through
`runtime_acquire_control`; read-only inspection and waiting do not.

Plugins may declare `:secret_env` configuration whose value is read from the
process environment and is never stored in the database.

## Bundled plugins

The Admin inventory is authoritative for the plugins installed on a particular
instance. The standard distribution includes:

- `admin_mysql` — default-disabled MySQL administration and diagnostics.
- `agent_activity` — agent-session activity views; enabled by default.
- `agent_insights` — default-disabled operational insight generation; depends on Agent Memory.
- `agent_memory` — persistent agent memory tools and settings; enabled by default.
- `agy_agent` — default-disabled Antigravity workflow/chat provider; requires a saved Gemini key.
- `alertmanager_investigations` — default-disabled Alertmanager-driven investigations.
- `attention_report` — default-disabled operator attention reporting.
- `browser` — loopback-only browser tools for workflow agents; enabled by default.
- `build_cache` — default-disabled shared dependency/build caching.
- `claude_agent`, `codex_agent`, `muse_agent` — default-disabled workflow/chat providers.
- `cognitive_review` — default-disabled cognitive review, optionally enhanced by Agent Memory.
- `container_execution` — default-disabled Docker execution backend.
- `coworkers` — default-disabled persistent coworker tasks; depends on Scheduled Tasks.
- `credential_store` — experimental, default-disabled credential management.
- `design_docs` — default-disabled collaborative design documents with
  `list_design_docs`, `read_design_doc`, `list_design_doc_sections`,
  `propose_design_doc`, `comment_on_design_doc`, `suggest_design_doc_change`,
  `archive_design_docs`, and `delete_design_doc` tools.
- `discord` — default-disabled Discord delivery, available after bot configuration.
- `django` — default-disabled Django previews; depends on Python.
- `git_history` — experimental, default-disabled repository history views.
- `git_mirror` — default-disabled local repository mirror; depends on Plugin Runtime.
- `github_host` — enabled GitHub repository-content host.
- `github_source` — enabled GitHub issue/PR input and source-control provider.
- `global_search` — enabled cross-product search.
- `go` — enabled Go setup, review, formatting, audit, and affected-test support.
- `ios` — enabled iOS project intelligence.
- `java` — experimental, default-disabled JVM project intelligence.
- `javascript` — enabled JavaScript/TypeScript setup, preview, review, autofix, and audit support.
- `k8s_cluster` — default-disabled Kubernetes tools; depends on Credential Store.
- `kotlin` — experimental, default-disabled Kotlin/JVM support; depends on Java.
- `linear_source` — default-disabled Linear input source.
- `metrics_dashboard` — default-disabled plugin-hosted metrics dashboard.
- `mockups` — enabled preview-panel tools: `write_preview_file`, `edit_preview_file`, `show_preview`, and `close_preview`.
- `mysql_db_browser` — default-disabled database connection and schema browser.
- `operator_briefing` — default-disabled operator briefing; depends on Agent Memory and Design Docs.
- `plugin_runtime` — default-disabled isolated runtime for plugin services.
- `python` — enabled Python setup, review, autofix, audit, and affected-test support.
- `ruby` — enabled Ruby setup, RSpec/RuboCop detail, review, autofix, audit, and affected-test support.
- `runtime_terminal` — default-disabled Runtime Session adapter; depends on Terminal.
- `scheduled_tasks` — enabled recurring and one-shot scheduled work.
- `sdlc_pipeline` — default-disabled repository delivery-pipeline view.
- `spending_insights` — default-disabled spending analysis.
- `syrus_dev` — default-disabled Syrus-development diagnostics and tools.
- `syrus-rails` — default-disabled Rails previews and tools; depends on Ruby.
- `tailscale` — default-disabled connectivity; depends on Plugin Runtime.
- `team_directory` — default-disabled operator directory and profiles.
- `terminal` — default-disabled interactive worker shells.
- `test_insights` — enabled test history, timing, and flakiness intelligence.
- `theming_tools` — default-disabled theme inspection tools.
- `throughput` — enabled delivery-throughput views, optionally integrated with Metrics Dashboard.
- `video_walkthroughs` — default-disabled narrated-video intake and analysis.
- `whisper_stt` — default-disabled local speech-to-text; depends on Plugin Runtime.
- `whiteboard` — enabled canvas tools: `read_scene`, `draw_shape`, `draw_text`,
  `draw_line`, `draw_arrow`, `draw_freedraw`, `draw_frame`, `draw_embed`,
  `draw_image`, `move_element`, `delete_element`, `update_scene`, `save_canvas`,
  `clear_canvas`, and `load_canvas`.
- `worker_timeline` — default-disabled worker and workflow timeline views.
