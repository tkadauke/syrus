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
- `repo_page_tab`
- `sidebar_page`
- `chat_mcp_tool_set`
- `source_control_provider`
- `prompt_injector`
- `artifact_renderer`
- `grader_augmentor`
- `callbacks`
- `prepare_detector`
- `review_criteria_provider`
- `autofix_command`
- `dependency_audit_command`
- `affected_test_analyzer`
- `workspace_tab`

Operators can inspect the registered plugins from **Admin → Plugins**
(`/admin/plugins`). The page shows each plugin's name, version, enabled state,
default enabled state, disableability policy, category, author/source metadata
when available, and every class registered for an extension point. Disableable
installed plugins can be enabled or disabled live; new requests and sidecars use
the latest `PluginRecord` state through `PluginRegistry.providers_for`.

The page filters plugins with the same chip-based `FilterBar` query builder
used on `/admin/queue` and `/admin/users` (no smart-folder saved-filter nav —
the `admin_plugins` `Filters::Subject` only needs the two chips below). A
`category` chip (`Filters::Chips::AdminPlugins::Category`, bucket `enum`,
values from `Syrus::Plugin::Category::ENTRIES`) filters by the taxonomy key;
its `is`/`is_not`/`is_one_of`/`is_none_of`/`is_set`/`is_unset` operators (from
the shared `Filters::Chips::EnumColumn` base) also make "uncategorized
plugins" (`is_unset`) directly filterable. A `search` chip
(`Filters::Chips::AdminPlugins::Search`, bucket `string`, `contains` only)
replaces the old plain-text search box and filters by name, display name,
description, and category — it delegates to `PluginRecord.search`, so it
keeps running as a real MySQL `FULLTEXT` `MATCH ... AGAINST` query in
production, with SQLite (dev/test) falling back to a `LIKE` scan. This is
still a plain per-table full text search, not the SQLite FTS5 `SearchRecord`
search engine used for Jobs/Epics/chat/operational logs. Both chips combine
with AND semantics. The filter tree is base64url-encoded into the `q` query
param on `GET /api/v1/app/admin/plugins`, which also returns `filter` (the
active tree) and `controls.filter_schema` (the chip definitions) for the
`FilterBar` component, exactly like `Admin::Queue::Payload`/`Admin::Users::Payload`.
The bearer-token `GET /api/v1/admin/plugins` API is unchanged: it keeps its
original plain-text `q=<text>` full-text search (via `Admin::PluginsPayload`'s
legacy `query:` argument), independent of the chip filter framework, so
existing external tooling built against it keeps working.

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

## Plugin categories (`category`)

A manifest's `category:` kwarg must resolve to a key from
`Syrus::Plugin::Category` (`lib/syrus/plugin/category.rb`) — the same small
registry-of-record pattern `Workflow::TriggerKind`/`Step::Kind` use, applied
to plugin categories instead of scattering ad hoc strings across engine
initializers. `Syrus::PluginRegistry.register` validates `category:` (when
present) against this list and raises `RegistrationError` for anything else;
a blank/absent category is still allowed, the same as a blank `author`.

| Key | Label | Bundled plugins |
|---|---|---|
| `language` | Language & framework intelligence | `ruby`, `javascript`, `python`, `go`, `syrus-rails`, `django` |
| `agent` | Agent provider | `claude_agent`, `codex_agent` |
| `input_source` | Input source | `github_source`, `linear_source` |
| `mcp_tool_set` | MCP tool set | `browser`, `preview_tools` |
| `platform_delivery` | Platform delivery | `discord` |
| `connectivity` | Connectivity | `tailscale` |
| `observability` | Observability | `admin_mysql`, `spending_insights`, `git_history` |
| `tooling` | Tooling | `syrus_dev` |

```ruby
Syrus::PluginRegistry.register(
  name: "my-plugin", version: "1.0.0",
  category: "language",
  provides: { prepare_detector: MyPlugin::PrepareDetector }
)
```

`Syrus::Plugin::Category.values` lists every valid key; `.label_for(key)`
returns the human-readable label. `Admin::PluginsPayload` emits both the raw
`category` key and a derived `category_label` in the Admin → Plugins JSON
payload, so the frontend never has to humanize the machine key itself.
`spec/plugins/plugin_categories_spec.rb` statically scans every bundled
plugin's manifest registration and fails if a plugin ships with no category,
or an unrecognized one — a newly added plugin can't merge without picking a
category from this table.

## Plugin icons (`icon_url`)

A manifest can set `icon_url:` to the path of a static SVG asset, e.g.:

```ruby
Syrus::PluginRegistry.register(
  name: "claude_agent", version: "1.0.0",
  icon_url: "/plugin-icons/claude_agent.svg",
  provides: { agent_provider: AgentProviders::Claude }
)
```

`Admin::PluginsPayload` always emits a non-null `icon_url` in the Admin →
Plugins JSON payload: the manifest's own value when set, otherwise
`/plugin-icons/spqr_eagle.svg` — an SPQR-style Roman legionary standard, the
same fallback the frontend's plugin icon lookup (`app/frontend/lib/pluginIcon.ts`)
falls back to for any plugin name it doesn't recognize. A plugin with no
natural brand mark (internal tooling, a connectivity daemon, etc.) is expected
to leave `icon_url` unset rather than invent one.

Icons are committed static SVGs under `public/plugin-icons/`, following the
same convention as the top-level Syrus brand icon (`public/icon.png`,
`app/frontend/lib/brandIcon.ts`): one small lookup, plain `<img>` rendering, no
bespoke component per icon, no runtime fetching or generation. They render at
Admin → Plugins, in the agent/chat provider selectors, and next to a
Workflow's detected-plugins list.

Format is SVG only — plugin icons only ever render small and inline, so a
single normalized vector file per plugin is sufficient and stays crisp at any
size; there is no multi-size raster set to generate or maintain.

Source real marks rather than fetching them at runtime, to avoid a licensing,
availability, or CDN-uptime dependency on some third party at request time.
Bundled plugins use [Simple Icons](https://simpleicons.org) (CC0-licensed,
already vector) for `ruby`, `syrus-rails`, `javascript`, `python`, `django`,
`go`, `github_source`, `discord`, and `linear_source`, and each provider's own
official mark where one is reasonably available under a CC0/Simple-Icons-style
license for `claude_agent`. Plugins without a suitable sourced mark (including
`codex_agent`, since no OpenAI/Codex mark is currently published through
Simple Icons) fall back to the SPQR eagle like any other unset `icon_url`.

`bin/process-plugin-icon SOURCE OUTPUT [--padding=FRACTION]` is an author-time
tool (uses the already-present `image_processing`/`ruby-vips` gems) that
normalizes a newly sourced icon's viewBox and padding so it sits consistently
next to the rest of the set, and rasterizes a raster-only source into an
embedded normalized SVG as a fallback. It is run by hand when adding or
updating an icon; it is never invoked by a workflow agent and has no presence
in the worker Docker image, the same way `public/icon.png` is a checked-in
static asset rather than something generated at runtime.

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

## `mcp_tool_set` / `chat_mcp_tool_set`

Contributes MCP tools to workflow agents (`mcp_tool_set`) or chat agents
(`chat_mcp_tool_set`). A plugin registers exactly one tool-set entrypoint per
surface — include `Syrus::Plugin::McpToolSet` or `Syrus::Plugin::ChatMcpToolSet`
and implement:

| Method | Signature | Description |
|---|---|---|
| `.tool_definitions` | `() → [{name:, description:, input_schema:}, ...]` (chat: `(tier:)`) | Every tool this set can offer |
| `.available_for?` | `(repository) → bool` (chat: `(chat_session, tier:)`) | Whether the set is offered at all |
| `#handle` | `(tool_name, params, server_context) → MCP::Tool::Response` | Dispatch a call |

Workflow tool sets may optionally implement `.available_for_context?(McpToolContext)`
and `.tool_definitions(context:)` when availability depends on the agent role
(e.g. only the `implement` step), not just the repository — see
`AdminMysql::WorkflowToolSet` and `SyrusDev::WorkflowToolSet`.

**One class per tool.** The entrypoint is a single class, but internally each
non-trivial tool is its own `MCP::Tool` subclass in its own file — the same
style core workflow/chat tools under `app/services/mcp/tools/` use — with
`tool_name`, `description`, `input_schema`, and a `.call(server_context:, **params)`
class method. The tool set holds a small `TOOL_CLASSES` array and dispatches
by name instead of growing a `case` statement:

```ruby
# app/services/my_plugin/read_widget_tool.rb
module MyPlugin
  class ReadWidgetTool < MCP::Tool
    tool_name "read_widget"
    description "Reads a widget by id."
    input_schema(type: "object", properties: { id: { type: "integer" } }, required: %w[id])

    def self.call(server_context:, id:)
      widget = Widget.find(id)
      MCP::Tool::Response.new([ { type: "text", text: JSON.generate(widget.as_json) } ])
    rescue StandardError => e
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end
  end
end

# app/services/my_plugin/mcp_tool_set.rb
module MyPlugin
  class McpToolSet
    include Syrus::Plugin::McpToolSet

    TOOL_CLASSES = [ ReadWidgetTool ].freeze

    def self.available_for?(_repository) = true

    def self.tool_definitions
      TOOL_CLASSES.map { |k| { name: k.tool_name, description: k.description_value, input_schema: k.input_schema_value.to_h } }
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |k| k.tool_name == tool_name.to_s }
      return MCP::Tool::Response.new([ { type: "text", text: "Unknown tool: #{tool_name}" } ], error: true) unless klass

      symbolized = (params || {}).each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      klass.call(**symbolized, server_context: server_context)
    end
  end
end
```

`Sidecar` always calls `#handle` with a raw `params` hash whose keys may be
strings (e.g. a JSON-decoded request or a test double) — symbolize before
splatting into `.call`'s keyword arguments, as above.

When several tools in one set share real logic (not just similar shape), pull
it into a small shared module or base class instead of duplicating it per
tool — `SyrusBrowser::BrowserTool` (a shared `MCP::Tool` base class for the
five browser tools that proxy to the same upstream Playwright MCP session)
and `PreviewTools::ToolSupport` (a mixin of response/panel-lookup helpers
used by all four preview tools) are the two real examples in this codebase.
Don't invent a shared abstraction for tools that don't actually share logic.

This convention is followed by `syrus_dev` (`SyrusDev::WorkflowToolSet`,
the original precedent), `syrus_rails` (`SyrusRails::McpToolSet`), `browser`
(`SyrusBrowser::McpToolSet`), `admin_mysql` (`AdminMysql::ChatToolSet`,
`AdminMysql::WorkflowToolSet`), and `preview_tools` (`PreviewTools::ChatToolSet`).

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

Draining is automatic, so plugin authors don't call `drain!` themselves. Both
places that dispatch lifecycle callbacks apply the same policy:
`PluginLifecycleJob` (operator-triggered `on_enable`/`on_disable`) and
`Syrus::PluginRegistry.fire_boot_callbacks!`/`fire_shutdown_callbacks!`
(process-wide `on_boot`/`on_shutdown`, called from
`config/initializers/plugin_registry.rb`'s `after_initialize` and `at_exit`).

- After `on_disable` or `on_shutdown`, effects always drain, even if the
  callback method itself raised — and even if the plugin never overrides
  `on_disable`/`on_shutdown` at all, since draining doesn't depend on the
  callback method doing anything.
- If `on_boot` or `on_enable` raises, whatever effects it managed to register
  before failing are drained immediately, then the error re-raises (or, for
  `fire_boot_callbacks!`, logged and swallowed the same way a plain `on_boot`
  failure already was). A failed enable never leaves an orphaned effect
  waiting for a disable that may never come.

`effect` isn't limited to the callbacks class itself — call it with an
explicit receiver from any collaborator that needs to register a cleanup at
the moment its own effect takes hold. `Tailscale::DaemonManager#start` does
exactly this: it calls `Tailscale::Callbacks.effect { stop }` immediately
after spawning the `tailscaled` process, before any of the steps that can
fail (`wait_until_ready!`, `run_tailscale_up!`, `run_tailscale_serve!`), so a
failure partway through startup still gets the daemon killed instead of
leaked.

## `prompt_injector`

Injects additional text into the agentic step's system prompt. Use this to instruct the agent to call `submit_artifact` when it touches specific files, or to add any other repository-specific guidance that should appear whenever the agent is writing code. Wired into `Steps::Implement` (`initial`/`retry` workflows), `Steps::Respond` (`pr_comment`/`chat_feedback` follow-up workflows), and `Steps::AnalyzeAndFix` (`ci_failure` repair) — the same call, with the same `repository:`/`job:` args, runs from all three so a repo-convention hint isn't lost on a follow-up or repair attempt just because it wasn't the first pass.

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

## `workspace_tab`

Lets a plugin add a tab to the chat sidebar's workspace panel, generalizing
what used to be a hardcoded closed union (`WorkspaceTab` in
`app/frontend/routes/chat/workspaceTabs.ts`, with a hardcoded render branch
per tab in `WorkspacePanels.tsx`).

**Design decision: declarative metadata + core glob discovery, not
plugin-owned rendering code.** Two shapes were considered for this extension
point:

- Option A — a plugin ships its own frontend rendering code, discovered by
  the frontend build from a `plugins/*/app/frontend/...` convention.
- Option B — a plugin only supplies declarative tab metadata (id, label,
  component tag) plus a fixed `renderer_type`-style dispatch, mirroring
  `:artifact_renderer`'s fixed `VALID_RENDERER_TYPES` list — rendering itself
  stays in core.

`:artifact_renderer` already answered this question one way (Option B, fixed
`renderer_type`) for a narrower problem: rendering a structured JSON payload
as one of a handful of known shapes (ERD, diff, table). A workspace tab is a
different problem — the concrete case this Epic exists to eventually migrate
is the whiteboard, a fully bespoke interactive Excalidraw canvas with its own
state, save/load, snapshotting, and fullscreen behavior. No fixed
`renderer_type` enum could stretch to cover that without either baking
whiteboard-specific rendering into core forever (defeating the point of
pluginizing it) or growing a new `renderer_type` for every future tab shape,
which is really Option A with extra ceremony.

So `:workspace_tab` follows `:admin_page`'s pattern instead (Option A, but
with the build tooling this codebase already has, not new tooling): a plugin
supplies declarative tab metadata via `Syrus::Plugin::WorkspaceTab`, and its
own React component, discovered by
`app/frontend/pluginWorkspaceTabs.tsx`'s `import.meta.glob("../../plugins/*/app/frontend/workspaceTabs/*.tsx")`
— the same `import.meta.glob` convention `app/frontend/pluginAdminPages.tsx`
already uses for admin pages. This was not new build-tooling to invent; it
was already proven for admin pages before this extension point existed.
Rendering is fully owned by the plugin's component (a real Excalidraw canvas,
in the whiteboard-migration Job this Epic sets up), while `.workspace_tabs`
metadata stays declarative so the core tab bar (id, label, ordering,
visibility) doesn't need to know anything about what's inside the tab.

Include `Syrus::Plugin::WorkspaceTab` and implement the class methods:

| Method | Signature | Description |
|---|---|---|
| `workspace_tabs` | `() → Array<Hash>` | Tab metadata: `id` (unique across all plugins — see collision guard below; conventionally prefixed `"<plugin_name>."`, checked by `spec/lib/syrus/plugin_workspace_tab_contract_spec.rb`), `label` (fallback string), `label_key` (`"<i18n_namespace>:<key>"`), `component` (frontend component key, matching a `frontend.workspace_tabs` manifest entry), and optional `order` (default `0`). |
| `available_for?` | `(chat_session) → bool` | Optional per-chat visibility gate. Defaults to always available. |

```ruby
class MyPlugin::WorkspaceTabs
  include Syrus::Plugin::WorkspaceTab

  def self.workspace_tabs
    [ { id: "my_plugin.status", label: "Status", label_key: "my_plugin:tab_status",
        component: "my_plugin/StatusTab", order: 100 } ]
  end

  def self.available_for?(chat_session) = chat_session.repository.present?
end

Syrus::PluginRegistry.register(
  name: "my_plugin", version: "1.0.0",
  frontend: {
    workspace_tabs: { "my_plugin/StatusTab" => "app/frontend/workspaceTabs/StatusTab.tsx" },
    i18n: [ "app/frontend/i18n/locales/*/my_plugin.json" ]
  },
  provides: { workspace_tab: MyPlugin::WorkspaceTabs }
)
```

`WorkspaceTabsPayload` resolves every enabled `:workspace_tab` provider's
`workspace_tabs` (filtered by `available_for?`, sorted by `order` then
`label`) into the chat payload's `workspace_tabs` array; `chat_payload` in
`app/controllers/concerns/chat_serialization.rb` includes it the same way it
already includes `preview_panels`. `Syrus::PluginRegistry.register` rejects a
second plugin registering a tab `id` already claimed by another plugin — the
same collision-guard pattern `:mcp_tool_set` uses for tool names — since two
tabs sharing an id would collide on the frontend's `plugin:<id>` React key
and tab-selection state.

On the frontend, `workspaceTabs.ts`'s `WorkspaceTab` union gained a
`PluginTab` variant (`` `plugin:${string}` ``, namespaced so a plugin's id
space can never collide with the fixed core tab names), the same shape
`PreviewTab` (`` `preview:${number}` ``) already established for preview
panels. `availableWorkspaceTabs()` appends one `plugin:<id>` entry per
payload `workspace_tabs` row; `WorkspacePanels.tsx` renders a tab button from
the declared `label`/`label_key` and, when active, lazily loads and mounts
the plugin's component via `pluginWorkspaceTabComponentFor`, passing the full
chat `payload` as a prop (a workspace tab renders inside one specific chat,
unlike a standalone admin route that derives its context from the URL).

The bundled `syrus_dev` plugin (default-disabled dev tooling — see below)
registers a trivial `SyrusDev::WorkspaceTabs` provider as a live, always-built
proof of this extension point, without moving any real feature into a plugin.

**First real consumer: `whiteboard_tools`.** The whiteboard migration (moving
the Excalidraw canvas tab, its 14 draw/move/delete/read/update/save/clear/load
MCP tools, and its REST endpoints out of core) landed as `plugins/whiteboard_tools`,
confirming the design above end-to-end and surfacing a few things worth
recording:

- **The `Whiteboard`/`WhiteboardSnapshot` models stayed in core** (`app/models/`),
  unrenamed. `Syrus::PluginModelNamespaceChecker` only requires namespacing for
  `ApplicationRecord` subclasses that physically live under `plugins/*/app/models/`
  — a plugin is free to depend on a core model it doesn't own, same as
  `preview_tools`' `ChatToolSet`/`ScratchDirectory` already depend on the core
  `PreviewPanel` model. Moving the model itself (rename + table migration) was a much
  larger, riskier change for no behavioral gain here, since `chat_session.whiteboard`/
  `chat_session.whiteboard_snapshots` association method names didn't need to change.
- **Fullscreen has no core hook, and doesn't need one.** The whiteboard tab's
  "fullscreen" affordance used to be a Chat.tsx-owned layout shift (hide the
  chat column and tab bar, resize the grid). `PluginWorkspaceTabProps` only
  hands a component `payload: ChatPayload` — no fullscreen prop/callback. Since
  Option A means the plugin owns its own rendering, `WhiteboardTab.tsx` now
  implements fullscreen entirely itself: local `useState`, a `document.body`
  portal (`ReactDOM.createPortal`) covering the viewport, and its own Escape-key
  listener. No core extension-point change was needed — a plugin tab can
  already do anything a normal React component can from inside `<Suspense>`.
- **The chat payload's `whiteboard` scene field needed no extension-point
  change either.** `PluginWorkspaceTabProps.payload` is the *full* `ChatPayload`,
  so a plugin tab can already read whatever core fields it needs (here,
  `payload.whiteboard` and `payload.paths.app_whiteboard_path`, both unchanged) —
  there's no need for a separate "per-tab data channel" on the extension point.
- **The "default active tab" heuristic became an explicit, documented core→plugin
  seam.** Before the migration, `defaultWorkspaceTab()` preferred `"whiteboard"`
  as the initial tab whenever the chat already had drawn content. That heuristic
  reads `payload.whiteboard` directly, so preserving it after the tab became
  plugin-owned meant `workspaceTabs.ts` now looks up the plugin tab by
  `component === "whiteboard_tools/WhiteboardTab"` — a literal string naming one
  specific plugin's tab, called out with a comment at its definition. This is the
  one piece of real, acknowledged coupling the migration introduced; there's no
  generic "which tab should be the default" hook on `:workspace_tab` today.
- **Found and fixed a real bug in `PluginRouteDispatch`** (`app/controllers/concerns/plugin_route_dispatch.rb`):
  every existing plugin route (`linear_source`, `syrus_dev`, `tailscale`, ...)
  happened to have no path parameters, so nobody had hit the fact that
  `request.path_parameters.merge!(route.params)` mutates the hash in place
  without invalidating Rails' separately-memoized `request.params`. Whiteboard's
  routes (`:id`, `:chat_id`) were the first plugin routes to need path params,
  which surfaced it — `params[:id]` was arriving `nil` at the controller even
  though `request.path_parameters` looked correct. Fixed by using the
  `path_parameters=` setter, which does invalidate the memo.
- **`@excalidraw/excalidraw` stays a root `package.json` dependency.** There's
  no plugin-scoped frontend dependency mechanism in this codebase (Vite
  resolves from the single root `node_modules` regardless of which plugin
  folder imports a package), so this is a known, accepted gap rather than
  something this migration solved.

## `grader_augmentor`

Allows plugins to append additional diagnostic output to the grade log when a
grader command fails. Augmentors are called after every failed grader run, before
the step raises `StepFailed`. They run in registration order; each may return
zero or more log lines. A single plugin can register more than one augmentor
by passing an array to the `:grader_augmentor` key (each guards on a distinct
grader command, e.g. one for the test runner and one for a linter) — see the
`ruby` plugin's `Ruby::GraderAugmentor`/`Ruby::RubocopGraderAugmentor` pair
below.

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

## Centralized per-repo plugin detection (`RepoPluginDetector`)

Every extension point that needs to know "does this plugin apply to this
repo" used to answer that question independently — `Syrus::PreviewProviderResolver`
calling `detect?` on each provider, `:prepare_detector` doing the same for
language plugins, `:mcp_tool_set` with its own `.available_for?(repo)`. Steps
run the same file-existence checks over and over, once per extension point,
per Step.

`RepoPluginDetector` centralizes this into a single computation per Run.
`Steps::Prepare` calls `RepoPluginDetector.for(workspace.path)` once, right
alongside `RepoPrepPlan.for`, and stores the result as the `detected_plugins`
Workflow artifact (see `config/syrus_docs/workflow_steps.md`). It reuses the
two extension points that already implement per-repo detection instead of
inventing a third mechanism:

- Every enabled `:prepare_detector` plugin's `detect?(repo_path)` (a class
  method — language plugins: `ruby`, `javascript`, `python`, `go`).
- Every enabled `:preview_provider` plugin's `detect?(repo_path)` (an
  instance method — framework plugins that don't register their own
  `:prepare_detector`, such as `syrus-rails` and `django`).

The result is the union of matching plugin manifest names (e.g.
`["ruby", "syrus-rails", "javascript"]`), computed fresh every Run rather than
cached on `Repository` — a repo's language mix can change over time (a
`Gemfile` added later, a plugin newly enabled), and the checks are cheap file
existence tests either interface already implements. Only currently-enabled
plugins are considered (`Syrus::PluginRegistry.all_plugins.select(&:enabled?)`),
so disabling a plugin instance-wide removes it from the detected set even if
its files still match.

Any Step in the same Run can read the result via `workflow.detected_plugins`
(an `Array<String>`, empty if `Steps::Prepare` hasn't run yet or found no
match) instead of re-deriving its own file-existence check — the intended
audience is extension points with no natural per-repo gate of their own, such
as `:prompt_injector` or a repository-scoped review-criteria provider. The Job
detail page's Workflows tab renders the set as a "Detected: …" line on each
workflow card.

## `review_criteria_provider`

Contributes default checklist items to the `adversarial_review` step's
reviewer prompt, without requiring the operator to configure `.syrus.yml`'s
`adversarial_review.criteria`. Wired into `Steps::AdversarialReview`, which
calls every registered (enabled) provider and concatenates the results with
`.syrus.yml`'s array before rendering `Prompts::AdversarialReview` — both
sources are additive on top of the reviewer's default checklist; there is no
override mechanism.

Include `Syrus::Plugin::ReviewCriteriaProvider` and implement the class method:

| Method | Signature | Description |
|---|---|---|
| `criteria` | `(repo_path) → Array<String>` | Checklist strings to add to the reviewer prompt, or `[]` to contribute nothing. Must not raise. |

```ruby
class MyPlugin::ReviewCriteriaProvider
  include Syrus::Plugin::ReviewCriteriaProvider

  def self.criteria(repo_path)
    return [] unless File.exist?(File.join(repo_path, "requirements.txt"))

    [ "Flag missing type hints on new public functions" ]
  end
end

Syrus::PluginRegistry.register(
  name: "my-plugin", version: "1.0.0",
  provides: { review_criteria_provider: MyPlugin::ReviewCriteriaProvider }
)
```

`repo_path` is the workflow workspace root (the same checkout the reviewer
inspects), available because `adversarial_review` runs after the workspace is
already set up. Providers typically gate their contribution on the same
repo-detection signal their `:prepare_detector` counterpart uses, so criteria
tuned for one ecosystem don't show up in an unrelated repo's review.

The `ruby`, `javascript`, `python`, and `go` plugins each register one seed
criterion, gated on the same signal their `:prepare_detector` uses:

| Plugin | Gate | Criterion |
|---|---|---|
| `ruby` | `Gemfile` present | Flag new N+1 query patterns in ActiveRecord code |
| `javascript` | lockfile/`package.json` present | Flag newly introduced `any` types |
| `python` | uv/poetry/pip signal present | Flag missing type hints on new public functions |
| `go` | `go.mod` present | Flag swallowed errors (`` `_ = err` ``) |

## `autofix_command`

Tells `Steps::Format` (see [`workflow_steps.md`](workflow_steps.md#format))
which deterministic formatter/linter-autocorrect shell command to run in the
workspace after the agentic step (`implement`/`respond`) and before the
grader retry loop's check phase, so a style-only grader failure the tool
could resolve for free doesn't cost the agent a full turn to notice and fix
by hand. Only used when the repo's `.syrus.yml` explicitly opts in with a
blank `formatters: []` — this is the opt-in signal for plugin defaults. A
repo with no `formatters:` key at all runs no formatting; a populated
`formatters:` array (or an explicit `formatters: false`/`off` disable)
takes over entirely and this extension point is not consulted. Present in
`initial`, `retry`, `pr_comment`, and `chat_feedback` workflows only.

Include `Syrus::Plugin::AutofixCommand` and implement the class method:

| Method | Signature | Description |
|---|---|---|
| `autofix_command` | `(workspace_path:) → String \| nil` | Return the shell command to run, or `nil` when this plugin's fixer doesn't apply to the repo (e.g. no config file for the tool). |

A plugin that offers more than one distinct fixer (e.g. ESLint and Prettier)
registers one provider class per fixer — each independently gated on its own
config signal — by passing an array to the `:autofix_command` key, the same
multi-provider pattern `:grader_augmentor` uses:

```ruby
class MyPlugin::AutofixCommand
  include Syrus::Plugin::AutofixCommand

  def self.autofix_command(workspace_path:)
    return nil unless File.exist?(File.join(workspace_path, "my-linter.toml"))

    "my-linter --fix ."
  end
end

Syrus::PluginRegistry.register(
  name: "my-plugin", version: "1.0.0",
  provides: { autofix_command: MyPlugin::AutofixCommand }
)
```

When `formatters: []` opts into plugin defaults, `Steps::Format` runs every
applicable command from every enabled plugin (union across plugins, ordered
by `prepare_priority` same as `:prepare_detector`) that this iteration's
diff is non-empty for, commits any resulting changes, and never fails the
workflow: a command that exits non-zero is logged as a non-fatal warning and
the step moves on to the next command, mirroring the soft-fail posture
`Steps::Prepare` uses for auto-detected (guessed) prepare commands.

The `ruby` plugin registers `Ruby::RubocopAutofix` (`bundle exec rubocop -a`,
gated on `.rubocop.yml`). The `javascript` plugin registers
`JavaScript::EslintAutofix` (`npx eslint --fix .`, gated on an ESLint config
file) and `JavaScript::PrettierAutofix` (`npx prettier --write .`, gated on a
Prettier config file or `package.json`'s `prettier` key). The `go` plugin
registers `Go::GofmtAutofix` (`gofmt -w .`, gated only on `go.mod` since
gofmt has no configuration surface to gate on further). The `python` plugin
registers `Python::RuffFormatAutofix` (`ruff format .`, gated on a ruff
config signal) and `Python::BlackAutofix` (`black .`, gated on a
`[tool.black]` table in `pyproject.toml`).

## `dependency_audit_command`

Tells `Steps::DependencyAudit` (see
[`workflow_steps.md`](workflow_steps.md#dependency_audit)) which dependency
vulnerability scan command to run for this ecosystem, and which lockfile(s)
in the PR diff should trigger it. Present in `initial`, `retry`,
`pr_comment`, and `chat_feedback` workflows only — the step is always in
those chains but self-skips unless the diff touched a matching lockfile.

Include `Syrus::Plugin::DependencyAuditCommand` and implement the class methods:

| Method | Signature | Description |
|---|---|---|
| `lockfiles` | `() → Array<String>` | Basenames of the lockfile(s) this provider's audit command applies to. `Steps::DependencyAudit` matches these against the PR diff's changed files (by basename) before running anything — a diff that never touches one of these files skips this provider entirely. |
| `audit_command` | `(workspace_path:) → String \| nil` | Return the shell command to run, or `nil` when this provider's audit tool doesn't apply (e.g. none of `lockfiles` actually exist on disk). |

A non-zero exit status from the returned command is not a tool error — it is
how bundler-audit/npm audit/pip-audit/govulncheck report that vulnerabilities
were found. `Steps::DependencyAudit` never fails the workflow or a grader on
a non-clean scan; it stores the results as a `dependency_audit` workflow
artifact, and — only when at least one scanned ecosystem is non-clean — a
`pr_comment_body` for `Steps::PrOpen`/`Steps::DependencyAuditPrComment` to
post. A clean scan across every scanned ecosystem is a silent no-op: no
comment gets posted.

A plugin whose ecosystem needs more than one distinct audit tool (e.g. a
different tool per package manager) registers one provider class per tool,
the same multi-provider pattern `:grader_augmentor`/`:autofix_command` use:

```ruby
class MyPlugin::DependencyAuditCommand
  include Syrus::Plugin::DependencyAuditCommand

  def self.lockfiles
    [ "my-lockfile.lock" ]
  end

  def self.audit_command(workspace_path:)
    return nil unless File.exist?(File.join(workspace_path, "my-lockfile.lock"))

    "my-audit-tool check"
  end
end

Syrus::PluginRegistry.register(
  name: "my-plugin", version: "1.0.0",
  provides: { dependency_audit_command: MyPlugin::DependencyAuditCommand }
)
```

The `ruby` plugin registers `Ruby::BundlerAuditCommand` (`bundle-audit check
--update`, gated on `Gemfile.lock` — the lockfile, not the `Gemfile` manifest
`:prepare_detector` keys off). The `javascript` plugin registers
`JavaScript::DependencyAuditCommand`, which reuses the same three true
lockfile names as `:prepare_detector`'s `PRIORITY` table (`yarn.lock` →
`yarn audit --json`, `pnpm-lock.yaml` → `pnpm audit --json`,
`package-lock.json` → `npm audit --json`) minus its `package.json` fallback,
since a bare `package.json` has no pinned dependency tree to audit. The
`python` plugin registers `Python::DependencyAuditCommand` (`pip-audit`,
gated on `uv.lock`/`poetry.lock`/`requirements.txt` — one tool covers every
lockfile flavor, unlike JavaScript's per-package-manager split). The `go`
plugin registers `Go::DependencyAuditCommand` (`govulncheck ./...`, gated on
`go.sum`).

## `affected_test_analyzer`

Lets `Steps::GraderFanout` (see
[`workflow_steps.md`](workflow_steps.md#grader_fanout) and
[`syrus_yml.md`](syrus_yml.md#when_files_changed)) refine a grader's
`when_files_changed` glob matching with real per-language import/dependency
analysis instead of relying on path patterns alone. A glob is a coarse proxy
for "which tests does this diff actually affect" — it can under-run (miss a
grader whose test files are affected only transitively, e.g. through a
shared library) as easily as it can over-run.

Include `Syrus::Plugin::AffectedTestAnalyzer` and implement the class method:

| Method | Signature | Description |
|---|---|---|
| `affected_files` | `(repo_path:, changed_files:) → Array<String> \| nil` | Given the repo checkout path and the diff's changed (repo-relative) files, return additional repo-relative paths transitively affected by the diff, or `nil` to decline — when the analyzer can't confidently resolve this diff. Must not raise; catch internally and return `nil` on unexpected error. |

`Steps::GraderFanout` only ever **adds** a provider's answer to the diff's
changed-file set before matching `when_files_changed` patterns against it —
it never removes files the raw diff already reported, and it never uses the
analyzer-expanded set for anything besides that match decision (the
`grade_plan_changed_files` artifact and its fingerprint, which
`LandingValidationCache` compares against plain `git diff --name-only`
fingerprints computed elsewhere, always reflect the literal diff). That
makes an analyzer's answer strictly additive and safe by construction: a
confident answer can turn a would-be skip into a run, but neither a declined
answer nor a raised error can ever cause a grader that would have run under
glob-only matching to be skipped. When no `:affected_test_analyzer` is
registered at all, or every registered provider declines or errors, grader
selection is identical to today's glob-only behavior.

```ruby
class MyPlugin::AffectedTestAnalyzer
  include Syrus::Plugin::AffectedTestAnalyzer

  def self.affected_files(repo_path:, changed_files:)
    # real import/dependency-graph analysis for this language
  end
end

Syrus::PluginRegistry.register(
  name: "my-plugin", version: "1.0.0",
  provides: { affected_test_analyzer: MyPlugin::AffectedTestAnalyzer }
)
```

The `ruby` plugin registers `Ruby::AffectedTestAnalyzer`, which combines a
`require_relative` reverse-dependency graph (a file that `require_relative`s
a changed file is itself treated as affected, even though the diff never
touched it) with the standard Rails/RSpec `app/x/y.rb` <-> `spec/x/y_spec.rb`
(and `lib/x/y.rb` <-> `spec/lib/x/y_spec.rb`) path convention, applied to
every affected file to find its own spec. It declines when the diff touches
no `.rb` files or when the repo's `app`/`lib` tree is too large to walk with
confidence on every `grader_fanout` call.

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

Sidebar-page plugins should declare:

- `sidebar_page` provider metadata with `id`, fallback `label`, `label_key`,
  `path`, `paths`, `component`, `icon`, and `order`.
- install-time `frontend.routes` metadata mapping component keys to plugin
  frontend files, the same way `admin_page` does.
- install-time `frontend.i18n` metadata listing plugin locale files.

`App::SidebarPagesPayload` (served over `GET /api/v1/app/sidebar_pages`) is
the sidebar analog of `Admin::PluginPagesPayload`: it calls
`Syrus::PluginRegistry.providers_for(:sidebar_page)` and returns each page's
metadata sorted by the declared `order`, falling back to
provider-registration order for ties. `app/frontend/routes/appChromeV2/sidebarNav.tsx`
merges those pages onto the end of `CORE_NAV_ITEMS` (the built-in primary
sidebar entries) for rendering in the primary sidebar nav; a freshly
registered plugin with `default_enabled: true` and no prior `PluginRecord`
row is treated as enabled without an operator opt-in step, same as any other
extension point.

Built-in workflow MCP tools are core app functionality, not a plugin. Optional
or installation-specific MCP tools should be contributed through plugin
`mcp_tool_set` providers.

### Repo-page-tab plugins

`repo_page_tab` mirrors `admin_page` for the repository detail page's tab bar,
with one difference: an admin page is instance-wide, but a repository tab's
visibility can vary by repository and by user, so the provider contract is a
method, not a static attribute:

```ruby
def self.repo_page_tabs(repository:, user:)
  # return [] to hide the tab for this repository/user pair
  [
    {
      id: "git_history.git_history",
      label: "Git History",
      label_key: "git_history:nav_git_history",
      path: "/repositories/#{repository.id}/plugin/git_history",
      paths: [ "/repositories/#{repository.id}/plugin/git_history" ],
      component: "git_history/GitHistory",
      order: 40
    }
  ]
end
```

`Repositories::PluginRepoTabsPayload` calls every registered `repo_page_tab`
provider with the current `repository:` and `user: Current.user`, normalizes
the descriptors (same shape as `admin_page`: `id`, `label`, `label_key`,
`path`, `paths`, `component`, `order`, optional `badge`), and:

- Backs `GET /api/v1/app/repositories/:repository_id/plugin_tabs`, which the
  frontend route resolver (`app/frontend/pluginRepoPageTabs.tsx`, mirroring
  `pluginAdminPages.tsx`) uses to find and lazy-render the right plugin
  component for the current repository and path.
- Feeds `RepositoryTabsSerialization#repository_tabs_json`, so every one of
  the six repository-scoped controllers (`repositories`, `repository_tests`,
  `insight_suggestions`, `repository_documents`, `scheduled_tasks`, and the
  dedicated plugin-tabs endpoint itself) shows the plugin's tab in the shared
  tab bar automatically — no per-controller wiring needed.

Repo-page-tab plugins should declare:

- `repo_page_tab` provider metadata implementing
  `self.repo_page_tabs(repository:, user:)`.
- install-time `frontend.routes` metadata mapping component keys such as
  `git_history/GitHistory` to plugin frontend files under
  `app/frontend/repo_tabs/` (a distinct glob convention from admin pages'
  `app/frontend/routes/` to avoid key collisions).
- install-time `frontend.i18n` metadata listing plugin locale files.
- install-time `routes` metadata for API routes (served the same way as
  admin-page plugin API routes) and, if the tab needs a hard-reload-safe SPA
  route, a `spa#show` entry whose `path` can include `:repository_id` —the
  host's `repositories/:repository_id/plugin/*path` route accepts any
  plugin-declared `spa#show` path shape via `PluginRouteResolver.spa_route_declared?`,
  not just exact literal paths like the admin `admin/*path` route.

Repo-page viewing itself (the repository detail page and its five sibling tab
endpoints) is available to both the repository owner and any
`RepositoryMembership` collaborator — see `Repository.accessible_to`.

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
  agents or operators should inspect Syrus's own production behavior. Also
  provides `:workspace_tab` (`SyrusDev::WorkspaceTabs` — a trivial "Workspace
  Tab Demo" tab, visible in chats attached to a repository, that exists only
  to prove the `:workspace_tab` extension point end-to-end; see above).
- `ruby` — default-enabled. Provides Ruby-generic extension points usable by
  any Ruby project (gems, Sinatra apps, plain Ruby scripts, and Rails apps
  alike), not just Rails: `:grader_augmentor` — registers two providers,
  `Ruby::GraderAugmentor` (appends structured RSpec JSON failure details to
  the grade log when an rspec grader fails) and `Ruby::RubocopGraderAugmentor`
  (appends compact `file:line: cop_name: message` lines parsed from RuboCop's
  `--format json` output under `.syrus/rubocop-json/*.json` to the grade log
  when a `rubocop` grader fails); `:test_result_parser` (`Ruby::RspecParser` —
  parses RSpec's plain progress/documentation output), `:coverage_analyzer`
  (SimpleCov's `.resultset.json`), `:prepare_detector` (`Gemfile` →
  `bundle install`, `prepare_priority: 10`), `:review_criteria_provider`
  (`Ruby::ReviewCriteriaProvider` — seeds a default adversarial-review
  criterion flagging new N+1 query patterns in ActiveRecord code, gated on
  the same `Gemfile` signal as `:prepare_detector`), `:autofix_command`
  (`Ruby::RubocopAutofix` — `bundle exec rubocop -a`, gated on `.rubocop.yml`
  being present), `:dependency_audit_command` (`Ruby::BundlerAuditCommand`
  — `bundle-audit check --update`, gated on `Gemfile.lock`), and
  `:affected_test_analyzer` (`Ruby::AffectedTestAnalyzer` — combines a
  `require_relative` reverse-dependency graph with the `app`/`lib` <-> `spec`
  path convention to report additional spec files a diff transitively
  affects).
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
  JS has no Rails-style built-in health endpoint). Also provides
  `:grader_augmentor` (`JavaScript::EslintGraderAugmentor` — appends compact
  `file:line: ruleId: message` lines parsed from ESLint's `--format json`
  output under `.syrus/eslint-json/*.json` to the grade log when an `eslint`
  grader fails). Also provides `:review_criteria_provider`
  (`JavaScript::ReviewCriteriaProvider` — seeds a default adversarial-review
  criterion flagging newly introduced `any` types, gated on the same
  lockfile/`package.json` signal as `:prepare_detector`). Also provides
  `:autofix_command` — two providers, `JavaScript::EslintAutofix` (`npx
  eslint --fix .`, gated on an ESLint config file) and
  `JavaScript::PrettierAutofix` (`npx prettier --write .`, gated on a
  Prettier config file or `package.json`'s `prettier` key). Also provides
  `:dependency_audit_command` (`JavaScript::DependencyAuditCommand` — picks
  `yarn audit --json`/`pnpm audit --json`/`npm audit --json` matching
  whichever of `:prepare_detector`'s true lockfiles is present).
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
  Also provides `:review_criteria_provider` (`Python::ReviewCriteriaProvider`
  — seeds a default adversarial-review criterion flagging missing type hints
  on new public functions, gated on the same uv/poetry/pip signal as
  `:prepare_detector`). Also provides `:autofix_command` — two providers,
  `Python::RuffFormatAutofix` (`ruff format .`, gated on a `.ruff.toml`/
  `ruff.toml` file or a `[tool.ruff]` table in `pyproject.toml`) and
  `Python::BlackAutofix` (`black .`, gated on a `[tool.black]` table in
  `pyproject.toml`). Also provides `:dependency_audit_command`
  (`Python::DependencyAuditCommand` — `pip-audit`, gated on
  `uv.lock`/`poetry.lock`/`requirements.txt`).
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
  differ). Also provides `:review_criteria_provider`
  (`Go::ReviewCriteriaProvider` — seeds a default adversarial-review
  criterion flagging swallowed errors (`_ = err`), gated on the same
  `go.mod` signal as `:prepare_detector`). Also provides `:autofix_command`
  (`Go::GofmtAutofix` — `gofmt -w .`, gated only on `go.mod` since gofmt has
  no configuration surface to gate on further). Also provides
  `:dependency_audit_command` (`Go::DependencyAuditCommand` —
  `govulncheck ./...`, gated on `go.sum`).
- `syrus_rails` (registered manifest name `syrus-rails`) — installed but
  disabled by default. `depends_on: [ "ruby" ]` — its Rails-specific tooling
  builds on the Ruby-generic support the `ruby` plugin provides; enabling
  `syrus_rails` cascades to enable `ruby`. Provides only genuinely
  Rails-framework-specific extension points: `:preview_provider` (starts a
  Rails server for preview hosting; health-checks `/up` only when
  `config/routes.rb` actually maps `rails/health#show`, else falls back to
  `/`; only launches `npm run dev` when `package.json` defines a `dev`
  script), `:mcp_tool_set`, `:artifact_renderer` (schema ERD and migration
  diff renderers), and `:prompt_injector`. Enable by calling
  `SyrusRails.register!` from an initializer.
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
- `preview_tools` — default-enabled. Provides `:chat_mcp_tool_set`
  (`PreviewTools::ChatToolSet`): `write_preview_file`/`edit_preview_file`
  (jailed to a `PreviewPanel`'s own scratch directory) plus
  `show_preview`/`close_preview`, letting a planning-mode chat agent build
  and preview an HTML/CSS/JS mockup or interactive widget page without
  touching the attached repository checkout. Unavailable in Coding Mode and
  Local Mode, which already have real Write/Edit tools. See
  `config/syrus_docs/preview_panels.md`.
- `spending_insights` — default-enabled; the first `sidebar_page` plugin.
  Provides `spending.dashboard`: label "Spending", `path`/`paths`
  `/insights/spending`, `component: "spending_insights/SpendingInsights"`,
  `icon: "spending"` (maps to `SpendingIcon` via `sidebarNav.tsx`'s
  `PLUGIN_ICONS`), `order: 60` — appended after `CORE_NAV_ITEMS`, so it
  renders at the end of the primary sidebar nav, above the pinned Supervisor
  chat block. The underlying cost-rollup data service
  (`App::SpendingPayload`, served over `GET /api/v1/app/insights/spending`)
  and its SPA shell route (`config/routes.rb`'s `insights/spending`) stay in
  core — only the nav entry, the `SpendingInsights.tsx` route component, and
  its `spending.json` locale files (`nav_spending` key) live in the plugin.
  Disabling the plugin removes the nav entry and makes `PluginSidebarPageRoute`
  render its "page unavailable" fallback for `/insights/spending`, but does
  not affect the JSON API endpoint itself.
- `whiteboard_tools` — default-enabled. Provides `:workspace_tab`
  (`WhiteboardTools::WorkspaceTabs`, unconditionally available) rendering the
  chat sidebar's Whiteboard tab (`plugins/whiteboard_tools/app/frontend/workspaceTabs/WhiteboardTab.tsx`,
  a real Excalidraw canvas with its own fullscreen handling — see the
  `:workspace_tab` section above), and `:chat_mcp_tool_set`
  (`WhiteboardTools::ChatToolSet`, tier `:deferred`): `read_scene`, `draw_shape`,
  `draw_text`, `draw_line`, `draw_arrow`, `draw_freedraw`, `draw_frame`,
  `draw_embed`, `draw_image`, `move_element`, `delete_element`, `update_scene`,
  `save_canvas`, `clear_canvas`, `load_canvas`. Registers its own
  `/api/v1/app/chats/:id/whiteboard` and `/api/v1/app/chats/:chat_id/whiteboard_snapshots`
  routes; the underlying `Whiteboard`/`WhiteboardSnapshot` models stay in core.
- `mysql_db_browser` — disabled by default (see
  `config/syrus_docs/mysql_db_browser.md`); the second `sidebar_page` plugin.
  `MysqlDbBrowser::SidebarPages` provides `mysql_db_browser.connections`:
  label "DB Browser", `path`/`paths` `/db_browser`,
  `component: "mysql_db_browser/MysqlConnections"`, `icon: "database"` (maps
  to `DatabaseIcon` via `sidebarNav.tsx`'s `PLUGIN_ICONS`), `order: 70`.
  Unlike `spending_insights`, its `sidebar_pages` method self-gates on both
  `MysqlDbBrowser.enabled?` (`PluginRecord.enabled` — the plugin's own
  enable/disable toggle is the feature gate, no separate `Feature` flag) and
  `Current.user&.admin?` and returns `[]` otherwise — the extension point
  itself has no per-page visibility concept, so admin-only sidebar pages must
  gate inside their own provider. `MysqlConnections.tsx` consumes the admin
  CRUD + test-connection API under `/api/v1/app/admin/mysql_connections` to
  list, add, edit, delete, and test connections; edit forms never receive a
  stored password back from the server. A "Browse Schema" button per
  connection switches the same page into a two-pane schema explorer
  (`SchemaBrowser`/`DatabaseNode`/`TableDetail` in the same file) backed by
  `MysqlDbBrowser::SchemaInspector` and the
  `GET /api/v1/app/admin/mysql_connections/:id/schema[/…]` routes — see
  `config/syrus_docs/mysql_db_browser.md` for the introspection design.
