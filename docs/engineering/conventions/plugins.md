# Plugins

Use these rules for plugin lifecycle, registration, boundaries, suggestions, and plugin-owned test coverage.

## Runtime invocation boundary

Core calls provider operations through `Syrus::PluginInvocation.call`, retaining
the `PerformanceLogging.plugin_call` timing seam while containing ordinary
provider failures. Return `Syrus::PluginInvocation.decline(value)` for an
expected refusal; expected declines are not health failures. Choose a neutral
decline value that preserves the extension point's composition contract: an
empty array for contributions, `nil` for an optional single answer, or `false`
for a predicate. Unexpected failures return a typed `Failed` result containing
that value, so callers can distinguish failure from an expected `Declined`.

Timeouts are opt-in and must have an explicit call-site budget. Ruby's
in-process `Timeout` can interrupt provider code at any point, including while
it mutates shared state or holds a lock, so only use it when the provider
operation and its dependencies are interruption-safe. This boundary contains
ordinary bugs, not malicious code, native-code hangs, memory growth, monkey
patches, or process termination.

The complete extension-point interfaces, examples, frontend integration rules,
icon pipeline, lifecycle hooks, and boundary tooling live in the
[plugin-authoring reference](plugins/authoring.md). To build a plugin outside
this repository, start with [Authoring an external plugin](plugins/external.md).

## Choosing the public host API

Public host APIs live under `Syrus::Host` and declare their contract beside the
facade with `Syrus::Host.api(name, since:, summary:, members:)`.
`Syrus::Host.apis` is the authoritative registry. A facade belongs there when
a typical external plugin needs it, its useful contract is small enough to
describe and smoke-test, and core can preserve it through a deprecation period.
Usage across bundled plugins is evidence for that choice, never the decision.

A core constant stays in the legacy inventory when bundled plugins still use
it but it is too broad, mutable, specialized, or coupled to a core subsystem
to support externally. The inventory is tolerated only for bundled plugins and
must shrink. Everything outside a declared host facade or the legacy inventory
is internal by default.

Alias a core constant into `Syrus::Host` only when the declared members are the
entire surface plugins should use and can be kept stable. Domain records are
never aliased: expose a read-oriented facade that wraps records and related
facades, names each supported lookup, attribute, and association, and does not
leak persistence, callbacks, credentials, state transitions, or unlisted
relations. Keep each summary short enough to state both its purpose and what it
deliberately does not promise; APIs needing a longer contract are not ready to
be public.

## Frontend contribution registry

Plugin frontend components are registered through
`app/frontend/pluginContributionRegistry.ts`. Registrations are keyed by
contribution kind, plugin name, and component key; registering the same tuple
again is a no-op. Values may be async module loaders or already-resolved
modules. Reads are synchronous, and external bundles can subscribe to registry
changes when they need to react to contributions added after first render.

In-repository plugins remain build-time modules. At application startup,
`app/frontend/builtInPluginContributions.ts` discovers their files and feeds
the same registry external bundles use. Component keys keep the public
`<plugin>/<Name>` format, and consumers continue loading plugin locales through
`loadPluginModule` before resolving the component.

Every plugin-contributed UI is rendered inside the shared plugin error boundary.
Render failures and rejected lazy imports report through the browser-error API
with the plugin name and show a compact localized reload action; they must not
escape into the surrounding application. Tool-card failures use this isolation
in expanded content and never change the design-locked one-line collapsed
header geometry.

External plugins declare locale JSON with `frontend.i18n` manifest patterns.
Locale files use `app/frontend/i18n/locales/{en,de,la}/<namespace>.json`; the
host advertises authenticated, content-hashed URLs and loads the active language
on demand. English is the required default and is used when an active-language
file is absent or fails to load. Bundled plugins retain the build-time locale
glob and `loadPluginModule` contract.

The currently registered contribution kinds are:

- `workspace_tab` for `plugins/*/app/frontend/workspaceTabs/*.tsx`
- `admin_page` for admin components in `plugins/*/app/frontend/routes/*.tsx`
- `sidebar_page` for sidebar components in `plugins/*/app/frontend/routes/*.tsx`
- `repo_page_tab` for `plugins/*/app/frontend/repo_tabs/*.tsx`
- `slug_preview_card` for `plugins/*/app/frontend/slugPreviewCards/*.tsx`
- `review_contribution` for `plugins/*/app/frontend/review_contributions/*.tsx`
- `review_annotation` for `plugins/*/app/frontend/review_annotations/*.tsx`
- `ui_slot` for `plugins/*/app/frontend/ui_slots/*.tsx`

- **A disabled plugin is not eager loaded.** Its `app/` dirs stay on the
  autoload path, so Zeitwerk resolves constants on demand and enabling needs no
  restart, but its code is skipped at eager load (`Syrus::PluginEagerLoad`,
  fails open if `plugin_records` is unreadable). Three states, not two:
  enabled runs `while_enabled` + `always` effects; disabled-but-enabled-before
  runs only `always` (the cleanup that keeps disabling from orphaning rows);
  never-enabled-here runs neither. `plugin_records.ever_enabled` is stamped by
  the model on any save while enabled and never cleared. Plugin migrations run
  at deploy time regardless of enabled state -- never from a runtime toggle.
- **A plugin can suggest itself.** `suggests_enabling(reason) { |signals| ... }`
  in the manifest is evaluated even for a plugin that is disabled and was never
  enabled -- the one tier that reaches an admin who does not know it exists. It
  returns evidence (a count, repo slugs) or falsy; no evidence, no nudge, and
  enabled plugins are never recommended. The block may only reach the plugin's
  `lib/` (required by the gem regardless of state), never its `app/` tree
  (not eager loaded while disabled). `Syrus::PluginSignals` supplies the facts;
  `repositories.plugin_signals` is stamped by `Steps::Prepare` from
  `RepoPluginDetector.observed_for`, which widens detection to installed-but-
  disabled plugins. Nudge-only -- it never gates a Step.
- **Plugin architecture** — Agent providers, chat providers, MCP tool sets,
  input sources, and source-control providers are registered as plugin gems
  via `Syrus::PluginRegistry`. Bundled plugins live under `plugins/` (e.g.
  `plugins/claude_agent`, `plugins/codex_agent`, `plugins/github_source`,
  `plugins/scheduled_tasks` — recurring/one-shot prompts,
  `plugins/syrus_dev` — development diagnostics/tooling, including the admin
  Performance UI's SQL explain and request/phase drilldowns,
  `plugins/video_walkthroughs` — narrated-screen-recording intake, Gemini
  analysis, and the chat handoff).
  `AgentProviders.for(provider)` resolves providers from the registry.
  When adding a new agent provider or MCP tool set, implement it as a plugin
  gem that calls `Syrus::PluginRegistry.register` in its engine initializer;
  don't add the class directly to `app/services/agent_providers/`.
- **Release compatibility** — External plugin gemspecs may declare
  `spec.metadata["requires_syrus"] = ">= 0.1.16"`. The value is a Ruby
  `Gem::Requirement` string and is validated before plugin code runs. Declare
  the oldest Syrus release the plugin has actually been tested against.
  Incompatible external plugins are withheld and reported in plugin health;
  when the running release is unknown the check is skipped and health explains
  why. Bundled plugins ship with core and are not checked.
  Run `bin/plugin-host-surface scan PATH` (optionally with `--json`) against an
  external plugin before publishing it. The scanner parses Ruby without
  executing it, allows APIs registered beneath `Syrus::Host`, reports legacy
  and unsupported core references, and derives the newest `since` release
  among the registered host APIs in use. Declare the oldest
  release actually tested as `requires_syrus`, but never below that derived
  floor. Static analysis cannot follow arbitrary dynamic constant lookup; it
  warns when literal core names are passed through `class_name`, `constantize`,
  `safe_constantize`, or `const_get`, but computed strings remain invisible.
- **Server-backed CLI commands** — A manifest may declare `cli_commands` as an
  array of command objects. Each object has a `path` array (nested command
  words), a one-line `summary`, a string `handler`, and optional `arguments`
  and `flags`. Parameters have a `name`, a `type` (`string`, `boolean`,
  `integer`, `enum`, or `repeatable_string`), and optional `required`,
  `default`, and (for enums) `values`. Handler strings are resolved lazily and
  must name a subclass of `Syrus::Plugin::CliCommandHandler`. Its
  `call(args:, flags:, user:)` method receives validated values and the
  authenticated API user; it must enforce normal policy authorization and
  return `self.class.table(columns:, rows:)`, `self.class.text(value)`, or
  `self.class.json(value)`. Commands cannot stream or prompt interactively.
  Invalid declarations degrade the plugin in plugin health and withhold its
  commands instead of preventing Syrus from booting.

  Commands that need local files, interactive prompts, agents, or child
  processes use a separately distributed `syrus-<name>` executable discovered
  on `PATH`. This is an independent binary target, not a package imported by
  the core CLI: plugin modules must not appear in `cli/go.mod` or `go.work`.
  ```ruby
  cli_commands [
    {
      path: %w[docs list],
      summary: "List design documents",
      handler: "DesignDocs::Cli::List",
      arguments: [ { name: "query", type: :string } ],
      flags: [
        { name: "state", type: :enum, values: %w[draft published] },
        { name: "tag", type: :repeatable_string, default: [] }
      ]
    }
  ]
  ```
- **Core specs must not enumerate plugin-provided things.** A bundled plugin is
  deletable — `bin/plugin-boundary-audit <name>` proves it by physically
  removing the plugin and running the suite in the copy — so a core spec that
  pins a plugin's MCP tool names, search types, smart-folder counts, or
  migration paths makes that plugin undeletable in practice. Subtract the
  plugin contribution and assert core's own set (`sidecar_registry_tool_names`
  in `spec/services/mcp_tool_registry_spec.rb` is the pattern), or move the
  example into the plugin that owns it. Specs that genuinely need a git working
  tree are tagged `:requires_git_checkout`. Same rule between plugins: a
  plugin spec may only name tools from a plugin it declares `depends_on`.
  See the [plugin-authoring reference](plugins/authoring.md) for the audit
  recipe.

## Plugin test kit

Plugin specs can require `syrus/plugin/test_kit` after `rails_helper`. The kit
uses only the installed plugin path and the running host, so the same spec runs
for a bundled plugin, a plugin under `SYRUS_PLUGIN_PATH`, or a plugin mounted in
a packaged Syrus image.

```ruby
require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe "weather tools host contract" do
  let(:plugin) { syrus_plugin(__dir__ + "/..") }

  it "satisfies the host contract" do
    expect(plugin).to be_plugin_loaded
    expect(plugin).to be_plugin_healthy
    expect(plugin).to register_plugin_provider(:callbacks)
    expect(plugin).to have_valid_plugin_manifest
    expect(plugin).to satisfy_requires_syrus
    expect(plugin).to have_clean_plugin_host_surface
    expect(plugin).to have_plugin_frontend
    expect(plugin).to have_matching_plugin_locales
  end
end
```

Route checks accept an `ActionDispatch::Integration::Session` through
`.using(session)`. CLI checks use `.executable_with(user)`. Migration checks
use `have_applicable_plugin_migrations`. `with_syrus_plugin(path) { |plugin| … }`
loads an arbitrary directory into a fresh registry snapshot and restores the
host registry afterward. `build_plugin_user`, `build_plugin_repository`, and
`build_plugin_job` provide minimal host records without making the underlying
test factories part of the public API. Provider implementations can use
`it_behaves_like "a valid Syrus plugin provider", :extension_point`.

## Definition of done for relocatable plugins

`bin/test-plugin-relocation` is the acceptance boundary for claiming that
plugins are relocatable. It copies a deliberately small, full-surface fixture
to a temporary `SYRUS_PLUGIN_PATH` outside the repository and proves discovery,
health and providers, routes, migrations, a prebuilt frontend contribution,
and server-backed CLI discovery and execution. The same check verifies version
incompatibility and load-failure isolation, then boots once more with the
plugin absent from both roots. Keep this acceptance test green whenever a
plugin surface or its discovery mechanism changes.
