import { registerEagerModules } from "./builtInPluginContributions"

type PluginModule = {
  default?: unknown
}

// Built-in plugin tool cards, registered eagerly because pluginToolCards.tsx
// reads them synchronously while rendering: a card's collapsed header must be
// complete on its first frame. Only that consumer imports this file;
// startup imports builtInPluginContributions.ts, which registers loaders only.
// These modules therefore arrive with the first chunk that renders them and
// are registered before its first render.
const toolCardModules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/tool_cards/*.tsx", "!../../plugins/*/app/frontend/tool_cards/*.test.tsx"],
  { eager: true }
)

registerEagerModules("tool_card", "tool_cards", toolCardModules)
