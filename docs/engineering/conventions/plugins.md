# Plugins

Use these rules for plugin lifecycle, registration, boundaries, suggestions, and plugin-owned test coverage.

The complete extension-point interfaces, examples, frontend integration rules,
icon pipeline, lifecycle hooks, and boundary tooling live in the
[plugin-authoring reference](plugins/authoring.md).

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
