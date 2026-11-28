import { registerEagerModules } from "./builtInPluginContributions"

type PluginModule = {
  default?: unknown
}

// Built-in plugin chat message renderers, registered eagerly because pluginChatMessageRenderers.tsx reads them
// synchronously while rendering. Only that consumer imports this file;
// startup imports builtInPluginContributions.ts, which registers loaders only.
// These modules therefore arrive with the first chunk that renders them and
// are registered before its first render.
const chatMessageRendererModules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/chat_message_renderers/*.tsx", "!../../plugins/*/app/frontend/chat_message_renderers/*.test.tsx"],
  { eager: true }
)

registerEagerModules("chat_message_renderer", "chat_message_renderers", chatMessageRendererModules)
