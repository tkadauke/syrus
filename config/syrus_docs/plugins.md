# Plugins

Plugins add optional capabilities to Syrus without making every installation
pay their runtime cost. A plugin can contribute agent and chat providers, MCP
tools, input and source-control integrations, previews, graders and review
helpers, repository content, execution backends, workspace tabs, admin or
repository pages, search sources, scheduled work, and other focused product
features.

The complete installed inventory is available under **Admin → Plugins**. Plugin
authors should use the engineering plugin-authoring reference (`docs/engineering/conventions/plugins/authoring.md` in the Syrus repository); this page describes behavior that operators and agents need when using plugins.
Each plugin detail page shows its manifest-declared capability families. The
same manifest-only inventory is available from `syrus plugin capabilities`.

Enabled, healthy plugins may also declare server-backed CLI commands. The CLI
catalog exposes nested command paths, summaries, positional arguments, and
flags in stable order. Execution uses the authenticated API user, so command
handlers must apply the same authorization policies as other requests. These
commands are non-interactive and non-streaming and return table, text, or JSON
results. Disabling a plugin immediately removes its commands from the catalog
and prevents execution.

The CLI fetches this catalog only while resolving a command that is not already
built in. It caches catalogs per instance with ETag revalidation and can use a
stale cached catalog while offline. Built-in commands take precedence over
catalog declarations. If neither matches, the CLI searches `PATH` from the
longest command path to the first word for a trusted `syrus-<path>` executable,
passes it the unmatched arguments, and exposes the configured instance and
token as `SYRUS_URL` and `SYRUS_TOKEN`.

The built-in local SDK commands are `syrus plugin new NAME`, `validate [DIR]`,
`test [DIR]`, and `dev [DIR]`. `new` creates a tested project; `validate` uses
an isolated, release-matched SQLite host; `test` also runs the plugin's RSpec
suite; and `dev` starts a disposable, reloadable host. Docker runners receive
the plugin directory but no instance credentials. Use `--syrus-version` to
select a release, `--json` for a machine-readable test summary, `--checkout`
for contributor testing, and `--keep-data` to retain a stopped dev instance.
The full authoring workflow and option reference live in
`docs/engineering/conventions/plugins/external.md`.

`syrus plugin dev [DIR]` runs one plugin in a throwaway, release-matched Syrus
container backed by SQLite. It prints the local URL and the seeded sign-in
(`demo@syrus.local` / `password`), enables the mounted plugin, and reports its
health. Frontend source changes are rebuilt inside the container; reload the
browser to fetch the new content-hashed bundle. Ruby, manifest, and locale
changes restart Syrus and print the resulting health, including load failures.
Ctrl-C removes the container and its data volume unless `--keep-data` is used,
which retains the stopped container and prints its name for later inspection.

The development instance supports one plugin and intentionally has no real
agent provider credentials. Configure a provider from the normal settings UI
if you want to exercise real agent calls; those credentials remain only in the
throwaway data volume. This command requires Docker and does not model MySQL or
a multi-worker deployment.

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

New installations leave agent-provider plugins, Build Cache, Local Backups, Design Docs,
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

## External plugin frontends

Plugins installed outside the Syrus repository can provide a prebuilt browser
bundle and stylesheet. Syrus loads these assets at startup only while the
plugin is enabled and healthy. A broken external bundle is logged and skipped;
it does not prevent the application from opening. Plugin styles are
self-contained and cannot rely on Syrus compiling plugin-specific Tailwind
classes.

Plugin authors build the conventional `frontend/entry.tsx` file with
`bin/build-plugin-frontend <plugin-dir>`. The bundle may import the host's
React, React DOM, TanStack Query, i18next, react-i18next, and
`@syrus/plugin-sdk` modules; those dependencies must remain external rather
than being copied into the plugin bundle.

## Installing an external plugin

An external plugin is trusted code that runs inside the Syrus process with its
database, filesystem, network, and credential access. Install only reviewed
plugin directories from trusted sources. Dropped-in plugins cannot add
third-party Ruby gems; they may depend on Rails and use Syrus's plugin APIs.

Set `SYRUS_PLUGIN_PATH` to a root whose immediate children are complete plugin
directories. Mount identical contents read-only at that path in every web,
worker, setup, preview, and other container that boots Rails. Stage a complete
directory, stop the Syrus processes, swap the directory into the shared root,
run the normal deployment migrations, and restart every Syrus container.
Plugin migration directories are discovered automatically and run even when a
plugin is disabled. Installing, replacing, or removing a plugin always requires
a full restart; enabling or disabling an already installed healthy plugin does
not.

After restart, open **Admin → Plugins** to check the plugin's version, health,
dependencies, routes, and load failures before enabling it. `incompatible`
means its `requires_syrus` range excludes the running release. `failed` means
discovery or loading raised an error, and `skipped_dependency` means a required
plugin did not load. Syrus isolates those plugins and withholds their routes
and providers so other plugins and core can continue booting.

To remove a plugin, disable it and resolve any in-use blockers, stop every
container, move its directory out of the shared root, and restart all
containers. Uninstalling retains plugin data and migrations for rollback;
purging data is a separate destructive operation.

For fleet-managed plugins, set `SYRUS_PLUGIN_SYNC_ENABLED=1` and distribute
the control plane's `SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY` to every Rails process.
The pre-boot sync reads the signed desired-state manifest and content-addressed
archives from the configured S3-compatible attachment bucket. In single-node
mode, `SYRUS_PLUGIN_SYNC_STORAGE_PATH` may point to the local attachment root.
It verifies the Ed25519 signature plus every archive's size and SHA-256 digest,
then atomically switches `$SYRUS_DATA_ROOT/plugin-sync/current`. The preceding
set remains at `last-good`, and hand-placed plugins in `SYRUS_PLUGIN_PATH`
continue to take precedence when a name occurs in both roots.

Storage, signature, manifest, and artifact failures print one error, retain the
last-good set, and allow boot. `SYRUS_PLUGIN_SYNC_STRICT=1` changes failures to
a nonzero exit for diagnostic or explicitly fail-closed processes.
`SYRUS_PLUGIN_SYNC_RETENTION` sets the number of additional inactive sets to
keep (default `2`). Fleet-quarantined and revoked entries are removed from the
activated set. Rails and spawned sidecars receive `SYRUS_PLUGIN_SET_DIGEST` and
`SYRUS_PLUGIN_SET_REVISION` for the active set.

Plugin manifests may declare `roles %w[web worker preview sidecar]`. Omitting
`roles` (or using an empty desired-state list) loads the plugin everywhere.
Only those four names are valid. An unlisted process skips the plugin and
records the reason in plugin health. Preview-provider, language, and framework
plugins must remain available to the `preview` role.

Desired-state changes do not hot-unload Ruby code. **Apply changes** records
the desired revision, gracefully drains web, worker, and preview processes,
and relies on the container supervisor to restart them in place. The entrypoint
then syncs before Rails boots. Setup and web apply plugin migrations through
the existing database preparation path; workers abort while migrations are
pending. Status reports each process as pending, restarted, or stuck. This is
tested with Docker Compose restart policies; native macOS workers and external
plugin distribution on Kubernetes are not supported by this flow.

Admin → Plugins also shows fleet convergence. A process is **converged** when
its role-specific plugin-set digest matches desired state. **Pending restart**
means an applied revision has not started there; **behind** means an older set
without a current restart request; **ahead** usually indicates the process is
connected to the wrong control plane or manifest store; and **unreachable**
means its heartbeat is stale. Restart pending/behind processes after verifying
sync configuration, investigate the control-plane connection for ahead
processes, and restore or replace unreachable processes. Per-plugin rows show
running versions plus local skips, failures, missing entries, and quarantine.

Divergence older than `SYRUS_PLUGIN_DIVERGENCE_THRESHOLD_SECONDS` (default:
300) is highlighted and emits the standard system alarm linked to the Plugins
page.

## Safe-mode recovery

`SYRUS_SAFE_MODE=third_party` withholds every hand-placed and synced plugin.
`recent` withholds external plugins whose content differs from the last good
boot, and `all` withholds every plugin; Syrus currently requires no plugin to
boot. The loader records every withheld plugin and reason in Admin → Plugins.

Boot attempts are stored in `$SYRUS_DATA_ROOT/plugin-boot-safety.json`, without
using the database. Three incomplete boots in ten minutes automatically
quarantine external plugins changed since the last good boot on the following
start. Override these defaults with `SYRUS_BOOT_FAILURE_LIMIT`,
`SYRUS_BOOT_FAILURE_WINDOW_SECONDS`, and `SYRUS_BOOT_SUCCESS_AFTER_SECONDS`.
A fleet quarantine in desired state is also applied at the next restart.

When the UI is available, the global warning links to Admin → Plugins; correct
the plugin and use **Re-enable after restart** for one plugin at a time. When
Rails cannot boot, run `bin/plugin-recovery list`, then
`bin/plugin-recovery quarantine NAME` or `bin/plugin-recovery clear NAME`.
Restart the affected processes after each change. Fleet quarantine must be
cleared in desired state rather than locally. Remove `SYRUS_SAFE_MODE` only
after the instance stays healthy, and reintroduce plugins one at a time.

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

An external plugin is `incompatible` when its `requires_syrus` requirement is
not satisfied by the running release. Syrus does not load the plugin or expose
its providers, and plugin health reports both the requirement and the running
release. When the running release is unknown, Syrus loads the plugin and notes
in plugin health that the compatibility check was skipped. Bundled plugins are
not checked because they ship with Syrus itself.

At discovery, Syrus statically scans an external plugin's Ruby files without
executing them. Registered `Syrus::Host` APIs are supported. Legacy APIs,
unsupported core references, literal dynamic core names, scan errors, and a
`requires_syrus` floor below the minimum derived from host APIs appear in
plugin health; direct unsupported references make the standalone scanner exit
non-zero. Literal names passed to `class_name`, `constantize`,
`safe_constantize`, or `const_get` are warnings because computed dynamic names
cannot be detected statically. The admin plugin detail page lists each finding
with its source file and line. Results are cached by Ruby content, so unchanged
plugins are not rescanned on every boot.

External plugin discovery, entry loading, engine construction, and provider
registration are isolated per plugin. A load error, syntax error, or other
exception marks that plugin `failed`; plugins with a hard dependency on it are
`skipped_dependency`. Duplicate external names are reported as
`duplicate_name`. None of these plugins contributes providers or routes, and
its engine declaration is made inert; the remaining plugins continue to load.

Bundled plugins remain
strict in development and test so defects are immediately visible; production
isolates and reports their failures in the same way as external plugins.

Plugin-owned routes follow the same environment rule. In development and test,
an unhandled controller exception propagates so the defect remains visible. In
production, Syrus contains the exception to that plugin, returns a structured
error naming it, and records the failure under **Admin → Plugins**. Plugin
health also shows each plugin's request count and the time of its latest route
error. Timestamp writes are rate-limited so a hot failing route does not create
unbounded health traffic. Each process retains at most 100 distinct recent
failure signatures per plugin, bounding both runtime memory and the Admin
health payload; a healthy plugin continues serving requests normally.

Runtime provider failures are isolated from core work and recorded under
**Admin → Plugins**. Repeated failures open a process-local circuit for that
plugin capability; calls decline without invoking the provider until one trial
is allowed after the cool-down. A successful trial closes the circuit, while a
failed trial opens it again. Because circuit state is process-local, different
web and worker processes can show different runtime histories.

Operators can tune the breaker for every process at startup:

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `SYRUS_PLUGIN_CIRCUIT_FAILURE_THRESHOLD` | `5` | Failures within the window that open a circuit. |
| `SYRUS_PLUGIN_CIRCUIT_WINDOW_SECONDS` | `60` | Sliding failure window in seconds. |
| `SYRUS_PLUGIN_CIRCUIT_COOLDOWN_SECONDS` | `30` | Delay before one trial call may run. |

Provider timeouts are opt-in at individual call sites rather than controlled by
a global setting. In-process isolation contains ordinary provider bugs; it
cannot contain malicious code, native-code hangs, memory growth, monkey
patches, or process termination.

Enablement can cascade through hard dependencies. Disabling a dependency can
cascade through its enabled dependents, but the admin must confirm the complete
set first. Disablement is rejected with a `plugin_in_use` HTTP 409 response when
active records or another runtime blocker still use the plugin.

## Plugin lifecycle

| Operation | Runtime behavior | Data |
| --- | --- | --- |
| Disable | Capabilities withheld, UI hidden, work skipped, routes report `plugin_disabled` | retained |
| Uninstall | Gem removed and no longer registered after restart | retained |
| Purge | Plugin-owned tables, declared shared-table fields and rows, and contributed external resources removed | destroyed |

Installation and uninstallation are manual: update the bundle, run migrations,
rebuild frontend assets when needed, and restart application processes. Purge is
an explicit, destructive operation performed only after uninstalling:

```sh
bin/rails 'plugin:data[build_cache]'    # preview what purge removes
bin/rails 'plugin:purge[build_cache]'   # confirm and destroy plugin data
```

The preview includes plugin-owned rows and fields stored inline on shared core
tables when the plugin ownership manifest explicitly declares how to remove
them. Purge deletes those rows and fields before dropping plugin tables, so it
does not leave dangling plugin references in retained core records.

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

## Capability families

Capability families group related, optional plugin contributions under one
contract. A plugin declares a provider class name plus the stable capabilities
it `implements`; provisional capabilities require a separate, explicit
`provisional` opt-in. Undeclared capabilities are never invoked. The manifest
and capability catalog remain readable while plugin code is unloaded, and a
disabled plugin contributes no capability providers.

Providers are ordered by the plugin's `prepare_priority`. Each capability
documents its context, stability tier, absent behavior, and one composition
mode: `collect`, `broadcast`, `first_claim`, or `keyed`.
Providers implementing a `keyed` capability declare the selector with `key:`
in the manifest, allowing selection without loading candidate classes.
Enabled providers are checked when plugin health is first resolved after boot.
Missing core methods, unknown capabilities, and incompatible signatures mark
the plugin non-conforming and withhold that family's declarations without
disabling unrelated registrations. Disabled plugins remain unloaded. Admin and
`syrus plugin capabilities` show declarations and conformance failures.

Core invokes a declared capability through `Syrus::Plugin::Dispatch.call`,
passing one immutable context object. The initial context shapes are
`RepoContext` (`repo_path`, `repository`), `WorkspaceContext`
(`workspace_path`, `changed_files`, `repository`), `GraderContext` (`name`,
`command`, `workspace_path`, `failed_cases`, `base_retry`, `project_path`), and
`JobContext` (`repository`, `job`). Providers accept the context as one
positional argument and read only the fields they need. Context fields are
additive: core may add a field without changing the provider method signature.

The dispatcher applies the capability's composition and absent behavior and
isolates every provider through plugin runtime health, timing, optional timeout,
and circuit-breaker handling. A crash or timeout becomes a neutral decline or
empty contribution. A missing keyed provider raises
`Syrus::Plugin::Dispatch::MissingKey`. Providers may raise
`Syrus::Host::CapabilityValidationError` for a deliberate caller-visible
configuration problem; validation errors do not count as plugin crashes.

## Background jobs

Plugin-owned Active Jobs subclass `PluginJob` and declare their owner with
`plugin :plugin_name`. They run on `plugin_<name>` by default, including jobs
from external plugins. Core jobs keep their existing queues.

The default cap is two concurrent jobs across a plugin's job classes. Raise it
with `plugin :plugin_name, concurrency: 5`, or use `queue_as` when one job has a
specific worker-placement requirement. Concurrency slots use a renewable
15-minute lease so long-running jobs remain capped while abandoned slots can
recover; plugins with an unusual recovery window can pass
`concurrency_duration: 30.minutes`. Ordinary failures retry five times with
polynomial backoff, then the job is discarded and recorded in plugin health.
The admin Queue and Plugins pages show plugin queue depth and failures.
