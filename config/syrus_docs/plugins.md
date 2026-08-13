# Plugins

Syrus plugins are Rails Engine gems that register extension point providers at
boot through `Syrus::PluginRegistry`. The registry currently supports:

- `agent_provider`
- `chat_provider`
- `mcp_tool_set`
- `input_source`
- `test_result_parser`
- `coverage_analyzer`
- `preview_provider`
- `admin_page`
- `chat_mcp_tool_set`
- `source_control_provider`
- `prompt_injector`
- `artifact_renderer`
- `grader_augmentor`
- `callbacks`

Operators can inspect the registered plugins from **Admin → Plugins**
(`/admin/plugins`). The page shows each plugin's name, version, enabled state,
default enabled state, disableability policy, category, author/source metadata
when available, and every class registered for an extension point. Disableable
installed plugins can be enabled or disabled live; new requests and sidecars use
the latest `PluginRecord` state through `PluginRegistry.providers_for`.

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
| `.renderer_type` | `Symbol` | One of `:erd_diagram`, `:migration_diff`, `:data_table`, `:before_after_diff` |
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
- `syrus_rails` — installed but disabled by default. Provides Rails-specific
  extension points: `:preview_provider` (starts a Rails server for preview
  hosting), `:mcp_tool_set`, `:test_result_parser` (RSpec output),
  `:coverage_analyzer` (SimpleCov), and `:grader_augmentor` (appends structured
  RSpec JSON failure details to the grade log when an rspec grader fails). Enable
  by calling `SyrusRails.register!` from an initializer.
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
  it to do.
