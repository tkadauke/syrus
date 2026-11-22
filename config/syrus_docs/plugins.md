# Plugins

Plugins add optional capabilities to Syrus without making every installation
pay their runtime cost. A plugin can contribute agent and chat providers, MCP
tools, input and source-control integrations, previews, graders and review
helpers, repository content, execution backends, workspace tabs, admin or
repository pages, search sources, scheduled work, and other focused product
features.

The complete installed inventory is available under **Admin → Plugins**. Plugin
authors should use the engineering plugin-authoring reference (`docs/engineering/conventions/plugins/authoring.md` in the Syrus repository); this page describes behavior that operators and agents need when using plugins.

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

`syrus plugin validate [DIR]` and `syrus plugin test [DIR]` are built-in local
SDK commands. They run the plugin in an isolated SQLite test host using the
release-matched plugin-test container; `test` continues from host validation to
the plugin's RSpec suite. `--syrus-version` selects a release, `--json` emits
the stable final summary, and `--checkout PATH` runs the identical entrypoint
from a contributor checkout. The test container never receives instance
credentials.

`syrus plugin pack [DIR]` validates the plugin and writes a deterministic
`.syrus-plugin.tar.gz` package. When a frontend source exists but its bundle is
missing, `--checkout PATH` uses that checkout's standard frontend builder.
Packages contain `package.json`, `CHECKSUMS.sha256`, and the complete plugin
tree under `plugin/`. The manifest records format version 1, plugin identity
and compatibility, declared capabilities and assets, public host APIs, and a
SHA-256 digest for every plugin file. Entries are sorted, timestamps are fixed,
and permissions are normalized, so identical inputs produce identical bytes.
Tar with gzip is used because it is streamable and supported by standard Unix,
Ruby, and Go tooling.

Packages may contain only regular files and directories. Absolute paths,
traversal components, links, duplicate entries, unlisted files, digest changes,
non-public host APIs, and third-party Ruby gem dependencies are rejected. The
validator also applies bounded file-count, individual-file, and total-size
limits. Package consumers and registry automation run
`bin/plugin-package-validate [--json] ARCHIVE`; a nonzero exit status means the
archive must not be accepted. Installer and registry integrations must consume
this same validation boundary instead of implementing parallel package checks.

Publishers create an Ed25519 key once with `syrus plugin keygen`, keep the
generated private-key file offline, and never commit or upload it. `syrus
plugin sign PACKAGE --key KEY` writes a detached signature over the package
SHA-256 digest. `syrus plugin verify PACKAGE --signature PACKAGE.sig
--trust-store TRUST.json` verifies provenance and prints `official`,
`verified`, or `community`; only an explicitly local package may be
`unsigned_local`.

The registry trust store lists publisher-key SHA-256 fingerprints and their
labels, plus revoked keys and releases. Revocation always wins: a revoked
package is refused and an installed release is fleet-quarantined for removal.
A signature proves which private key signed the exact bytes. It does not
sandbox the plugin, review its code, or authorize its tools.

`syrus plugin publish DIR --key KEY --repository OWNER/REPO` validates, packs,
signs, and uploads a GitHub release, then prints its registry entry. Passing
`--index-repository OWNER/INDEX --submit` explicitly consents to opening the
index pull request. Authentication is read from `GITHUB_TOKEN` and is not
printed or stored.

`syrus plugin new NAME` creates a complete external plugin project in `./NAME`
or the empty directory selected by `--path`. It rejects invalid Ruby namespace
names and names that collide with installed or CLI-bundled plugins. The
baseline includes a provider, three matching locales, host-contract specs, and
CI that runs `syrus plugin test`. `--frontend`, `--model`, and `--cli` add the
corresponding examples; `--syrus-version` overrides the generated
`requires_syrus` requirement.

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

## Installing an external plugin

An external plugin is trusted code that runs inside the Syrus process with its
database, filesystem, network, and credential access. Install only reviewed
plugin directories from trusted sources. Dropped-in plugins cannot add
third-party Ruby gems; they may depend on Rails and use Syrus's plugin APIs.

For packaged plugins, an administrator uploads the archive on **Admin →
Plugins** or runs `syrus plugin install PATH`. Syrus validates the package and
signature, rejects revoked releases, and stages a capability manifest for
review. Staging does not change desired state. Confirmation is explicit; CLI
scripts use `--yes`. The capability manifest is disclosure, not enforcement,
and plugin tools still use normal permissions. Updates and removals follow the
same confirmation gate. After confirmation, **Apply changes** synchronizes the
active set and restarts the fleet. `syrus plugin list` reports versions, trust,
sources, and health; `syrus plugin remove NAME` stages removal. Import/export
lockfiles record name, version, digest, and source while the database remains
canonical.

`syrus plugin install NAME[@VERSION]` first reuses a stored release, which
supports rollback, then consults the synchronized git registry index at
`$SYRUS_DATA_ROOT/plugin-registry/index/NAME/VERSION.json`. Each entry contains
`name`, `version`, `artifact_url`, and `signature_url`; artifact URLs must use
HTTPS. Omitting the version selects the highest indexed semantic version. The
downloaded archive and detached signature pass through the same validation,
trust, storage, and confirmation path as an upload.

Set SYRUS_PLUGIN_REGISTRY_URL on the instance to enable the admin registry
browser, or in the CLI environment to enable `syrus plugin search [TERM]`
directly against an HTTPS mirror or HTTPS Git URL. It is unset by default.
Search returns only releases compatible with the running or connected Syrus
version and omits revoked releases. Registry errors are non-fatal, and a valid
cached index remains available when refresh fails.

For legacy hand placement, use the following stopped-process procedure.

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

When `.syrus.yml` has no explicit `prepare:`, enabled Ecosystem providers with
the `detect_prepare` capability inspect the repository and contribute setup commands. Typical
detections include Ruby
Bundler, JavaScript package managers, Python uv/Poetry/pip, Go modules, and JVM
Gradle or Maven wrappers. Commands run in priority order and identical commands
are deduplicated. Detected version files may cause the matching toolchain to be
installed through mise before setup. `prepare: []` or `prepare: false` opts out.

### Autofix, audits, affected tests, and review criteria

The Ecosystem family's `autofix` capability contributes formatters or safe autofixes.
Setting `formatters: []` opts into all applicable plugin defaults; an autofix
failure is reported but does not fail implementation. `dependency_audit`
adds ecosystem vulnerability checks. `affected_tests` expands changed
files into likely affected tests. `review_criteria` seeds relevant
repository review criteria without overriding repository configuration.

### Build-system imports

An Ecosystem provider implementing `target_graph` may import targets into `target_graph.imports`:

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

Capability families declare provider capabilities, stability, composition
(`collect`, `broadcast`, `first_claim`, or `keyed`), and absent behavior.
Undeclared capabilities and providers from disabled or non-conforming plugins
are not called; Admin and `syrus plugin capabilities` show the declarations.
Core dispatches each call with one immutable repository, workspace, grader, or
Job context whose fields are additive. Providers read only the fields they need.
Calls share timing, timeout, health, and circuit-breaker isolation, so crashes
become neutral contributions. Missing keyed providers and intentional
`Syrus::Host::CapabilityValidationError` failures remain caller-visible.

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
