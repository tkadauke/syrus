// Static plugin name -> icon URL lookup, mirroring the same
// public/plugin-icons/*.svg assets and SPQR-eagle fallback
// Admin::PluginsPayload serves as `icon_url` (see config/syrus_docs/plugins.md).
// Surfaces that already have a plugin's `icon_url` from the admin API should
// render that value directly; this lookup is for surfaces that only know a
// plugin by name (provider selectors, the Workflow detected-plugins list)
// and don't fetch the full admin payload. Follows the same convention as
// app/frontend/lib/brandIcon.ts: one file, a small lookup, plain rendering,
// no bespoke component per icon.
const FALLBACK_ICON_URL = "/plugin-icons/spqr_eagle.svg"

const KNOWN_PLUGIN_ICONS: Record<string, string> = {
  ruby: "/plugin-icons/ruby.svg",
  "syrus-rails": "/plugin-icons/syrus-rails.svg",
  javascript: "/plugin-icons/javascript.svg",
  python: "/plugin-icons/python.svg",
  django: "/plugin-icons/django.svg",
  go: "/plugin-icons/go.svg",
  github_source: "/plugin-icons/github_source.svg",
  discord: "/plugin-icons/discord.svg",
  linear_source: "/plugin-icons/linear_source.svg",
  claude_agent: "/plugin-icons/claude_agent.svg"
}

// agent_provider/chat_provider values ("claude", "codex") are shorter than
// the plugin manifest names ("claude_agent", "codex_agent") they map to.
const PROVIDER_PLUGIN_NAMES: Record<string, string> = {
  claude: "claude_agent",
  codex: "codex_agent"
}

export function pluginIconSrc(pluginName: string): string {
  return KNOWN_PLUGIN_ICONS[pluginName] || FALLBACK_ICON_URL
}

export function providerIconSrc(provider: string): string {
  return pluginIconSrc(PROVIDER_PLUGIN_NAMES[provider] || provider)
}
