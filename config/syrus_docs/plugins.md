# Plugins

Syrus plugins are Rails Engine gems that register extension point providers at
boot through `Syrus::PluginRegistry`. The registry currently supports:

- `agent_provider`
- `chat_provider`
- `mcp_tool_set`
- `input_source`
- `test_result_parser`
- `coverage_analyzer`
- `ci_log_parser`
- `preview_provider`
- `admin_page`
- `chat_mcp_tool_set`
- `source_control_provider`
- `prompt_injector`
- `artifact_renderer`
- `grader_augmentor`
- `callbacks`
- `prepare_detector`

Operators can inspect the registered plugins from **Admin → Plugins**
(`/admin/plugins`). The page shows each plugin's name, version, enabled state,
default enabled state, disableability policy, category, author/source metadata
when available, and every class registered for an extension point. Disableable
installed plugins can be enabled or disabled live; new requests and sidecars use
the latest `PluginRecord` state through `PluginRegistry.providers_for`.

The page's search box filters plugins by name, display name, description, and
category via a `q` query param on `GET /api/v1/app/admin/plugins` (and the
bearer-token `GET /api/v1/admin/plugins`). `PluginRecord` mirrors those
manifest fields onto plain columns (kept in sync by
`Syrus::PluginRegistry.upsert_plugin_record!`) so the search can run as a real
MySQL `FULLTEXT` `MATCH ... AGAINST` query in production; SQLite (dev/test)
falls back to a `LIKE` scan via `PluginRecord.search`. This is a plain
per-table full text search, not the SQLite FTS5 `SearchRecord` search engine
used for Jobs/Epics/chat/operational logs.

Installation and enablement are deliberately separate. Installed plugin gems are
loaded at boot, so their Ruby code, controllers, frontend modules, and i18n
files are available after deploy/restart. Runtime enablement only decides
whether extension points are visible or usable. Disabling a plugin hides admin
pages and removes providers/tools from registry lookups, but it does not unload
compiled JavaScript or locale strings.

Availability is reported per extension point. Agent and chat providers run the
provider class's `.available?` check. Input sources show how many repository
`InputSource` records use that source class. Source-control providers identify
which installed plugin owns branch, PR, and merge operations for a repository;
they are separate from input sources because polling and PR operations are not
the same capability. MCP tool sets are listed as registered because their
runtime availability depends on the repository context that invokes the sidecar.
Test result parsers and coverage analyzers are listed as registered parser
classes.

## Plugin dependencies (`depends_on`)

A plugin manifest can declare `depends_on: ["other_plugin_name"]` — an array of
other plugin names it needs to function:

```ruby
Syrus::PluginRegistry.register(
  name: "syrus-rails", version: "1.0.0",
  depends_on: [ "ruby" ],
  provides: { preview_provider: SyrusRails::PreviewProvider }
)
```

This is a real relationship, not just an illustrative example: the bundled
`syrus_rails` gem (`plugins/rails`, registered manifest name `"syrus-rails"`)
declares `depends_on: [ "ruby" ]` because its Rails-specific tooling assumes
the Ruby-generic RSpec/SimpleCov/Gemfile support the `ruby` plugin provides.
Enabling `syrus-rails` cascades to enable `ruby`; disabling `ruby` while
`syrus-rails` is enabled surfaces the confirmation/cascade-disable path
described below.

Dependency names are validated once boot settles, from the same
`Rails.application.config.after_initialize` block that calls
`fire_boot_callbacks!` — plugin engine initializer order isn't guaranteed, so a
dependency may register after the plugin that depends on it, and validation has
to wait until every engine has had a chance to register. An unresolved
`depends_on` name (misspelled, or the dependency plugin was never installed) is
logged as an error rather than crashing boot, since a bad `depends_on` in one
plugin gem shouldn't be able to take down the whole instance.

This declaration drives two behaviors in Admin → Plugins:

- **Enabling** a plugin cascades to enable every plugin in its `depends_on`
  chain, transitively, silently. There is no confirmation step, since enabling
  is additive and safe.
- **Disabling** a plugin checks whether any other currently-enabled plugin
  depends on it, transitively. If so, the API responds with
  `{ requires_confirmation: true, plugin_name:, dependents: [...] }` instead of
  disabling anything; the frontend shows the dependent plugin names and asks
  the operator to confirm. Retrying the request with `confirm_cascade: true`
  disables the target plugin and every one of those dependents together, in a
  single transaction. This is independent of `Admin::PluginDisableGuard`'s
  existing hard blockers (configured users/repositories/chats/input
  sources/etc., which still return a `409 plugin_in_use` and block the
  disable outright) — a plugin can be blocked by usage, have dependents, both,
  or neither.

`Admin::PluginDependencyGraph` computes both the transitive dependency and
dependent sets from the registered manifests and is cycle-safe. The API
payload for each plugin includes its declared `depends_on` array and a derived
`dependents` array (every plugin — enabled or not — that transitively depends
on it), so the relationship is visible on the Admin → Plugins page even before
an operator tries to disable anything.

## `:preview_provider`

Preview providers tell Syrus how to start, seed, and health-check a preview
application for a repository. The provider is selected at runtime by
`Syrus::PreviewProviderResolver.for(repo_path)`, which calls `detect?` on each
registered provider in order and returns the first match.

A repository's explicit `.syrus.yml preview:` section takes precedence over
plugin auto-detection. Providers should supply safe framework defaults; repos
with production-specific guardrails should declare them in `.syrus.yml`.

Include `Syrus::Plugin::PreviewProvider` and implement the interface methods:

| Method | Signature | Description |
|---|---|---|
| `detect?` | `(repo_path) → bool` | True if this provider handles the repo |
| `start_command` | `(port:) → String` | Shell command to start the server |
| `setup_commands` | `() → Array<String>` | Commands to prepare the fresh preview checkout before seed/start |
| `seed_command` | `() → String \| nil` | Command to seed the database (nil = skip) |
| `health_check_path` | `() → String` | URL path polled to determine readiness |
| `log_paths` | `() → Array<String>` | Log paths (relative to repo root) to tail |
| `env` | `() → Hash<String, String>` | Environment variables to set for setup, seed, and server commands |
| `unset_env` | `() → Array<String>` | Inherited environment variables to remove for setup, seed, and server commands |

Register an instance using the direct form:

```ruby
Syrus::PluginRegistry.register(:preview_provider, MyPlugin::PreviewProvider.new)
```

Or via a gem manifest:

```ruby
Syrus::PluginRegistry.register(
  name: "my-plugin", version: "1.0.0",
  provides: { preview_provider: MyPlugin::PreviewProvider }
)
```

Select a provider programmatically:

```ruby
provider = Syrus::PreviewProviderResolver.for(repo_path)
# => SyrusRails::PreviewProvider instance, or nil if nothing matches
```

**SQLite requirement:** the preview host launches the Rails server in a
long-lived child process. For the preview database to work without a companion
Postgres container, the repo's `config/database.yml` must use
`adapter: sqlite3` for the `development` environment. Postgres preview
environments are not yet supported.

## `callbacks`

Plugins that include `Syrus::Plugin::Callbacks` participate in the lifecycle
event system. Five nil-default methods can be overridden:

| Method | When called |
|---|---|
| `on_boot` | Every process, after Rails `after_initialize` |
| `on_shutdown` | Every process, via `at_exit` |
| `on_enable` | When an operator enables the plugin at runtime (via `PluginLifecycleJob`) |
| `on_disable` | When an operator disables the plugin at runtime (via `PluginLifecycleJob`) |
| `on_tick` | On a recurring schedule declared by `tick_interval` (via `PluginTickJob`) |

All five methods are available as class methods on the provider thanks to the
module's `included` hook, which calls `base.extend(self)`. Plugins only need
to override the methods they care about; the nil defaults make the others silent
no-ops.

Register a callbacks provider:

```ruby
class MyPlugin::LifecycleCallbacks
  include Syrus::Plugin::Callbacks

  def self.on_boot
    Rails.logger.info("[MyPlugin] booted")
  end

  def self.on_enable
    MyPlugin::Daemon.start!
  end

  def self.on_disable
    MyPlugin::Daemon.stop!
  end

  def self.on_tick
    MyPlugin::Daemon.heartbeat!
  end
end

Syrus::PluginRegistry.register(
  name:          "my_plugin",
  version:       "1.0.0",
  home_queue:    :control_plane,
  tick_interval: 30.seconds,
  provides:      { callbacks: MyPlugin::LifecycleCallbacks }
)
```

`home_queue:` (default `:default`) is the Solid Queue queue used for
`PluginLifecycleJob` and `PluginTickJob`. `:default` means the job's
class-level `queue_as` declaration applies. Use a named queue such as
`:control_plane` when the plugin owns long-running daemon processes that
require queue isolation.

`tick_interval:` (optional ActiveSupport duration) declares how often the
plugin wants `on_tick` fired. Wiring the recurring Solid Queue task for a
specific plugin is done via `config/recurring.yml` or the plugin engine's own
initializer.

`on_enable` and `on_disable` are enqueued asynchronously via `PluginLifecycleJob`
from a `PluginRecord` `after_commit` callback whenever the operator toggles a
plugin's enabled state through Admin → Plugins.

### Effect registration (`effect`)

Pairing an `on_enable`/`on_boot` side effect with a hand-written
`on_disable`/`on_shutdown` teardown method means the inverse has to be
reconstructed by hand and kept in sync separately — easy to let drift, and it
does nothing for a side effect that only got half set up before a later step
in the same call raised. Register the cleanup at the point the effect actually
takes hold instead, with the class-level `effect(&cleanup)` helper
`Syrus::Plugin::Callbacks` provides:

```ruby
class MyPlugin::LifecycleCallbacks
  include Syrus::Plugin::Callbacks

  def self.on_enable
    MyPlugin::Daemon.start!
    effect { MyPlugin::Daemon.stop! }
  end
end
```

`effect` resolves the including class's own plugin name from
`Syrus::PluginRegistry.all_plugins` (raising if the class isn't registered as
some plugin's `callbacks` provider) and delegates to
`Syrus::Plugin::EffectRegistry.register`, a mutex-guarded, per-plugin-name
stack of cleanup procs. `Syrus::Plugin::EffectRegistry.drain!(plugin_name)`
pops and runs every registered cleanup for that plugin, most-recently-registered
first — LIFO, the natural inverse of setup order — then clears the stack. A
cleanup that raises is rescued and logged rather than blocking the rest.

`PluginLifecycleJob` drains automatically, so plugin authors don't call
`drain!` themselves:

- After `on_disable` or `on_shutdown`, effects always drain, even if the
  callback method itself raised.
- If `on_boot` or `on_enable` raises, whatever effects it managed to register
  before failing are drained immediately, then the error re-raises. A failed
  enable never leaves an orphaned effect waiting for a disable that may never
  come.

`effect` isn't limited to the callbacks class itself — call it with an
explicit receiver from any collaborator that needs to register a cleanup at
the moment its own effect takes hold. `Tailscale::DaemonManager#start` does
exactly this: it calls `Tailscale::Callbacks.effect { stop }` immediately
after spawning the `tailscaled` process, before any of the steps that can
fail (`wait_until_ready!`, `run_tailscale_up!`, `run_tailscale_serve!`), so a
failure partway through startup still gets the daemon killed instead of
leaked.

## `prompt_injector`

Injects additional text into the implementing agent's system prompt. Use this to instruct the agent to call `submit_artifact` when it touches specific files, or to add any other repository-specific guidance that should appear in every implement run.

Providers are registered via the **direct** form (an instance or lambda, not a class in a `provides:` manifest), since injectors are typically lightweight closures:

```ruby
Syrus::PluginRegistry.register(
  :prompt_injector,
  ->(repository:, job:) {
    next unless repository.slug.start_with?("myorg/")
    "If you modify db/schema.rb, call submit_artifact with type 'rails_schema_erd'."
  }
)
```

Or using the module interface for a class-based provider:

```ruby
class MyInjector
  include Syrus::Plugin::PromptInjector

  def call(repository:, job:)
    "Custom instructions for #{repository.slug}."
  end
end

Syrus::PluginRegistry.register(:prompt_injector, MyInjector.new)
```

The provider's `call` method receives `repository:` (the `Repository` record) and `job:` (the `Job` record). Return a `String` to inject, or `nil` to inject nothing. Returning `nil` is safe and skips the provider silently. Multiple registered injectors all run; their outputs are concatenated in registration order after the issue content.

## `artifact_renderer`

Maps agent-submitted artifact types to a core frontend renderer. Include
`Syrus::Plugin::ArtifactRenderer` and implement two class methods:

| Method | Returns | Description |
|---|---|---|
| `.artifact_type` | `String` | Artifact type identifier (e.g. `"rails_schema_erd"`) |
| `.renderer_type` | `Symbol` | One of `:erd_diagram`, `:migration_diff`, `:data_table`, `:before_after_diff`, `:image_diff` |
| `.payload_schema` | `Hash\|nil` | Optional JSON Schema for the payload (documentation only, not validated) |

A plugin may register multiple renderer classes by passing an array to the
`:artifact_renderer` key:

```ruby
Syrus::PluginRegistry.register(
  name: "syrus_rails", version: "1.0.0",
  provides: { artifact_renderer: [SchemaErdRenderer, MigrationDiffRenderer] }
)
```

When a job's workflow contains `typed_artifacts`, the job detail page annotates
each entry with the matching `renderer_type` from registered renderers and
displays them in the **Artifacts** tab. Artifacts with no registered renderer
fall back to a raw JSON display.

## `grader_augmentor`

Allows plugins to append additional diagnostic output to the grade log when a
grader command fails. Augmentors are called after every failed grader run, before
the step raises `StepFailed`. They run in registration order; each may return
zero or more log lines.

Include `Syrus::Plugin::GraderAugmentor` and implement the class method:

| Method | Signature | Description |
|---|---|---|
| `augment_grader_failure` | `(name:, command:, workspace_path:) → Array<String>\|nil` | Return an array of lines to append (each ending with `"\n"`), or `nil`/`[]` to add nothing. Must not raise. |

Parameters:

- `name` — grader name from Step details (e.g. `"rspec"`)
- `command` — the grader shell command that was run
- `workspace_path` — `Pathname` pointing to the workflow workspace root

Example use case: reading structured JSON failure output that a test runner
wrote to a well-known path and surfacing it as compact human-readable lines in
the run log, so the agent sees every failing test even when plain-text stdout
was truncated.

```ruby
class MyPlugin::GraderAugmentor
  include Syrus::Plugin::GraderAugmentor

  def self.augment_grader_failure(name:, command:, workspace_path:)
    return nil unless command.include?("my-runner")
    report = workspace_path.join(".my-plugin/results.json")
    return nil unless report.exist?
    JSON.parse(report.read).fetch("failures", []).map { |f| "FAILED: #{f}\n" }
  rescue JSON::ParserError
    nil
  end
end

Syrus::PluginRegistry.register(
  name: "my-plugin", version: "1.0.0",
  provides: { grader_augmentor: MyPlugin::GraderAugmentor }
)
```

## `prepare_detector`

Tells `RepoPrepPlan` which shell commands to run in a freshly-cloned
workspace before handing off to the agent, based on signals in the repo
(lockfiles, config files, etc). This is the auto-detect fallback used when a
repository has no `.syrus.yml` `prepare:` list.

Include `Syrus::Plugin::PrepareDetector` and implement the class methods:

| Method | Signature | Description |
|---|---|---|
| `detect?` | `(repo_path) → bool` | True if this plugin's ecosystem is present in the repo |
| `prepare_commands` | `(repo_path) → Array<String>` | Commands to run |
| `mise_version_file` | `() → String or nil` | Optional. The mise version-pin filename this ecosystem owns (e.g. `.ruby-version`). Defaults to `nil`. |
| `span_labels` | `() → Array<[Regexp, String]>` | Optional. Regex → label pairs for naming this ecosystem's sub-commands in grader command span display (e.g. `[/\brspec\b/, "rspec"]`). Defaults to `[]`. |

`RepoPrepPlan` queries every enabled `:prepare_detector` plugin whose
`detect?` matches and **concatenates** their `prepare_commands` — the union
is across plugins/ecosystems, not within one. A plugin fronting more than one
package manager for the same ecosystem (e.g. both `yarn.lock` and
`package-lock.json` present) must still pick exactly one command internally;
returning more than one command per package manager it fronts is a plugin
bug, not something `RepoPrepPlan` dedupes.

```ruby
class MyPlugin::PrepareDetector
  include Syrus::Plugin::PrepareDetector

  def self.detect?(repo_path)
    File.exist?(File.join(repo_path, "requirements.txt"))
  end

  def self.prepare_commands(repo_path)
    [ "pip install -r requirements.txt" ]
  end
end

Syrus::PluginRegistry.register(
  name: "my-plugin", version: "1.0.0",
  prepare_priority: 100,
  provides: { prepare_detector: MyPlugin::PrepareDetector }
)
```

`prepare_priority` (an `Integer`, default `100`, lower runs/orders first) is a
general manifest field that controls the order commands from different
plugins are concatenated in. Plugins that don't set it keep their
registration order relative to each other.

The `ruby` plugin registers a `:prepare_detector` for `Gemfile` →
`bundle install` at `prepare_priority: 10`. The `javascript` plugin registers
a `:prepare_detector` for Node/JS (and TS) repos at `prepare_priority: 20`,
internally picking exactly one package-manager command in priority order:
`yarn.lock` → `pnpm-lock.yaml` → `package-lock.json` → `package.json`. The
`python` plugin registers a `:prepare_detector` for Python repos at
`prepare_priority: 30`, internally picking exactly one command in priority
order: `uv.lock` → `uv sync`, `poetry.lock` → `poetry install`,
`requirements.txt` → `pip install -r requirements.txt`, else bare
`pyproject.toml` → `pip install -e .`. The `go` plugin registers a
`:prepare_detector` for `go.mod` → `go mod download` at `prepare_priority: 40`
— Go modules have a single package-manifest signal, so there's no
priority list to pick between.
`RepoPrepPlan` no longer hardcodes any Ruby or Node fallback signals — every
auto-detected command comes from a registered `:prepare_detector` plugin.

### `mise_version_file`

`Steps::Prepare` runs `mise install` before any prepare commands when the
workspace contains a mise version-pin file. The two universal triggers
(`.tool-versions`, `.mise.toml`) are always recognized, regardless of which
plugins are registered. Per-language version-pin filenames come from each
enabled `:prepare_detector` plugin's `mise_version_file` instead of a
hardcoded list: the `ruby` plugin declares `.ruby-version`, `javascript`
declares `.node-version`, `python` declares `.python-version`, and `go`
declares `.go-version`. A disabled plugin's version file no longer triggers
`mise install`. `mise_version_file` is independent of `detect?` — the version
file can be present even when the plugin's own primary signal (`Gemfile`,
`package.json`, etc.) isn't.

### `span_labels`

`GraderCommandSpans::Plan` names each sub-command phase in the live
worker-health UI (`read_run_worker_health`) by checking every enabled
`:prepare_detector` plugin's `span_labels` — in `prepare_priority` order —
before a handful of remaining genuinely language-agnostic labels it owns
directly (`website build`, `migration checks`, `eager load check`,
`production build boot`), then falling back to a generic "first 3 words"
label built from the sub-command itself. The `ruby` plugin declares labels
for `bundle check`, `bundle install`, `db:test:prepare`, `rspec`, and
`rubocop`; `javascript` declares `frontend tests` and `frontend build`;
`python` declares `pytest`, `ruff`, and `mypy`; `go` declares `go test`,
`go vet`, and `go build`. This is display polish only — a plugin that
doesn't declare `span_labels` still gets a usable generic label, never an
error.

## `ci_log_parser`

Lets a plugin claim a CI log before `CiLogParser` falls back to its own
built-in parsers — same "plugin tries first, core generic parser is the
fallback" pattern as `:test_result_parser` and `:coverage_analyzer`.
`CiLogParser#parse` feeds the diagnostic summary a `ci_failure` repair agent
sees (`error_summary`, `failing_tests`/`offenses`, `error_block`).

Include `Syrus::Plugin::CiLogParser` and implement the class method:

| Method | Signature | Description |
|---|---|---|
| `call` | `(text:, step_name:) → Hash\|nil` | Return a result Hash (see below), or `nil` if this parser doesn't recognize the log — control passes to the next registered `:ci_log_parser` plugin and, eventually, to `CiLogParser`'s own fallback parsers. |

Parameters:

- `text` — the CI log, already scoped to the failing step
- `step_name` — the failing step's name, or `nil`

The returned Hash needs `parser:`, `error_summary:`, and `error_block:`; it
may also include `failing_tests:` and/or `offenses:` (both default to `[]`).
Providers are tried in registration order; the first non-nil result wins. A
result missing the required keys, or a raised exception, is treated the same
as `nil` — logged and skipped — so one misbehaving plugin degrades to the
next parser instead of breaking CI-failure diagnosis for every check.

```ruby
class MyPlugin::CiLogParser
  include Syrus::Plugin::CiLogParser

  def self.call(text:, step_name: nil)
    return unless text.match?(/^Traceback \(most recent call last\):/)

    { parser: "pytest", error_summary: "pytest failure", error_block: text }
  end
end

Syrus::PluginRegistry.register(
  name: "my-plugin", version: "1.0.0",
  provides: { ci_log_parser: MyPlugin::CiLogParser }
)
```

## Plugin install and uninstall

Plugin install and uninstall remain manual operations: edit the Gemfile, run
Bundler, run migrations if the plugin ships any, rebuild frontend assets when
the plugin ships JS/i18n, and restart the Rails processes so plugin engine
initializers register with the in-memory registry.
Non-disableable plugins are forced enabled. Avoid them unless there is a strong
compatibility reason: core runtime pieces should generally live in the core app,
not in the plugin registry.

Admin-page plugins should declare:

- `admin_page` provider metadata with `id`, fallback `label`, `label_key`,
  `path`, `paths`, `component`, `order`, and optionally `group_id`.
- install-time `frontend.routes` metadata mapping component keys such as
  `syrus_dev/AdminPerformance` to plugin frontend files.
- install-time `frontend.i18n` metadata listing plugin locale files.
- install-time `routes` metadata for API and SPA routes. The host serves
  `/admin/*` through the SPA for plugin pages. API routes declared under
  `/api/v1/app/*` or `/api/v1/admin/*` are served by the host plugin-route
  dispatcher after concrete core routes, so plugin controllers can live inside
  the plugin engine without adding one-off host routes.

The `group_id` field slots the plugin's admin page into one of the core
navigation groups in the Admin sidebar. Valid values:

| `group_id` | Admin section |
|---|---|
| `operations` | Operations (Queue, Stuck, Reconciler Activity, Processes) |
| `observability` | Observability (Console, Resource Admission) |
| `users_access` | Users & Access (Users, Invitations, GitHub App, Installations) |
| `system` | System (Settings, Features, Plugins) |
| `product_data` | Product Data (Scoped Chat Events, Insights) |

Plugin pages with an unrecognized or absent `group_id` appear ungrouped at the
bottom of the sidebar below the named sections. Omit `group_id` (or set it to
`nil`) for standalone pages that do not belong to any group.

Built-in workflow MCP tools are core app functionality, not a plugin. Optional
or installation-specific MCP tools should be contributed through plugin
`mcp_tool_set` providers.

## Adding a plugin

1. Create a gem directory under `plugins/<name>/`.
2. Define your provider class, `include Syrus::Plugin::<InterfaceModule>`, and implement the interface methods.
3. Implement a `register!` class method (or engine initializer) that calls `Syrus::PluginRegistry.register(...)`.
4. Add a spec under `spec/plugins/<name>/` covering `detect?`, primary methods, and the registry integration.
5. Load the plugin by calling `YourPlugin.register!` from a Rails initializer or at Syrus boot.

Bundled plugins:

- `claude_agent` / `codex_agent` — default-enabled workflow and chat providers.
- `github_source` — required GitHub issue/PR polling source and source-control
  provider. It is installed as a plugin for source ownership, but is not
  disableable yet because some GitHub behavior still lives in core.
- `linear_source` — installed but disabled by default until configured.
- `discord` — installed but disabled by default until an operator sets
  `AppSetting.discord_bot_token`. Provides the `:platform_delivery`
  extension point (`Discord::PlatformAdapter`); see
  `config/syrus_docs/external_platforms.md` for the Gateway connector
  details.
- `syrus_dev` — installed but disabled by default. It owns Syrus-development-only
  diagnostics such as Admin → Performance and the `read_performance_diagnostics`
  / `read_syrus_logs` workflow MCP tools. Enable it only on instances where
  agents or operators should inspect Syrus's own production behavior.
- `ruby` — default-enabled. Provides Ruby-generic extension points usable by
  any Ruby project (gems, Sinatra apps, plain Ruby scripts, and Rails apps
  alike), not just Rails: `:grader_augmentor` (appends structured RSpec JSON
  failure details to the grade log when an rspec grader fails),
  `:test_result_parser` (`Ruby::RspecParser` — parses RSpec's plain
  progress/documentation output), `:coverage_analyzer` (SimpleCov's
  `.resultset.json`), and `:prepare_detector` (`Gemfile` → `bundle install`,
  `prepare_priority: 10`).
- `javascript` — default-enabled. Provides `:prepare_detector` for Node/JS
  (and TS) repos — identical detection applies to both, since npm/yarn/pnpm/bun
  and `package.json` don't distinguish JS from TS. Internally picks exactly one
  package-manager command in priority order: `yarn.lock` →
  `pnpm-lock.yaml` → `package-lock.json` → `package.json`
  (`prepare_priority: 20`). Also provides `:preview_provider`: detects a
  `package.json` whose `scripts` object has a `dev` or `start` key, and
  starts the preview via `PORT=<port> npm run <script>` (preferring `dev`
  over `start`). `setup_commands` reuses the same lockfile priority table as
  `:prepare_detector` instead of re-implementing package-manager detection.
  `seed_command` is `nil` (no cross-ecosystem JS seeding convention) and
  `health_check_path` stays at the interface default `/` (a soft guess —
  JS has no Rails-style built-in health endpoint).
- `python` — default-enabled. Provides `:prepare_detector` for Python repos,
  internally picking exactly one install command in priority order:
  `uv.lock` → `uv sync`, `poetry.lock` → `poetry install`,
  `requirements.txt` → `pip install -r requirements.txt`, else bare
  `pyproject.toml` → `pip install -e .` (`prepare_priority: 30`);
  `:grader_augmentor` (appends compact `FAILED: test_name — message` lines
  parsed from `pytest --json-report` output under `.syrus/pytest-json/*.json`
  to the grade log when a `pytest` grader fails); and a light, unconditional
  `:prompt_injector` reminding the agent to activate/use a virtual
  environment or dependency-manager run-prefix. Does not provide a custom
  `:test_result_parser`/`:coverage_analyzer` — plain `pytest --junitxml=`
  output is already handled by core's `JunitXmlParser` fallback and
  `coverage xml` (Cobertura format) is already handled by
  `CoverageAnalysis::Parsers::Cobertura`, both via `.syrus.yml` wiring only.
- `go` — default-enabled. Provides `:prepare_detector` for Go repos: `go.mod`
  → `go mod download` (`prepare_priority: 40`). Does not provide a custom
  `:test_result_parser` — plain `gotestsum --junitfile=report.xml ./...`
  output is already handled by core's `JunitXmlParser` fallback, same as the
  `python` plugin's `pytest --junitxml=` case, via `.syrus.yml` wiring only.
  Does not provide a `:coverage_analyzer` either, but unlike Python this is a
  genuine gap: `go test -coverprofile=coverage.out` has no built-in XML/lcov
  export. Convert it instead of writing new Ruby — `gocov`+`gocov-xml` to
  Cobertura, or `gcov2lcov` to lcov — then wire the result into `.syrus.yml`'s
  `coverage.sources[].format`; see the plugin README for both command
  sequences. No `:preview_provider` — no single universal Go web-serving
  convention exists at the language level (net/http, Gin, Echo, etc. all
  differ).
- `syrus_rails` (registered manifest name `syrus-rails`) — installed but
  disabled by default. `depends_on: [ "ruby" ]` — its Rails-specific tooling
  builds on the Ruby-generic support the `ruby` plugin provides; enabling
  `syrus_rails` cascades to enable `ruby`. Provides only genuinely
  Rails-framework-specific extension points: `:preview_provider` (starts a
  Rails server for preview hosting), `:mcp_tool_set`, `:artifact_renderer`
  (schema ERD and migration diff renderers), and `:prompt_injector`. Enable
  by calling `SyrusRails.register!` from an initializer.
- `django` — installed but disabled by default. `depends_on: [ "python" ]` —
  its Django-specific tooling builds on the Python-generic support the
  `python` plugin provides (prepare detection, pytest grader detail);
  enabling `django` cascades to enable `python`. Provides only
  `:preview_provider`: detects a Django repo via `manage.py` plus an
  importable `DJANGO_SETTINGS_MODULE` settings module, boots
  `python manage.py runserver`, migrates and optionally seeds via
  `fixtures/seed.json` (`manage.py loaddata`), and falls back to `/` for the
  health check since Django has no Rails-style built-in endpoint — repos
  without a 2xx/3xx root route should set `preview.health_check` in
  `.syrus.yml`.
- `browser` — default-enabled. Provides `:mcp_tool_set`
  (`SyrusBrowser::McpToolSet`): granular headless-browser tools
  (`browser_navigate`, `browser_click`, `browser_fill`, `browser_snapshot`,
  `browser_screenshot`, `browser_wait_for`, `browser_close`) for workflow
  agents, backed by a bundled `@playwright/mcp` stdio subprocess (Chromium
  ships in the worker Docker image only — see `Dockerfile`'s `worker-deps`
  stage). One browser session is spawned per Run and reused across every
  `browser_*` call in that Run; it is killed when the workflow step's MCP
  sidecar exits. `browser_navigate` is hard-restricted to loopback URLs
  (`SyrusBrowser::LoopbackGuard`) — an agent driving a real browser can only
  reach the worker's own `start_preview` preview, never an arbitrary network
  destination, regardless of what a prompt or a compromised target repo asks
  it to do. Also provides `:artifact_renderer` (`SyrusBrowser::ImageDiffRenderer`,
  type `visual_review_screenshot` → `:image_diff`) — `browser_screenshot`
  itself only returns image content to the agent's own context, so an agent
  that wants a screenshot to survive as a durable, operator-visible artifact
  calls the core `submit_visual_artifact` MCP tool (see
  `config/syrus_docs/typed_artifacts.md`) to persist it.
