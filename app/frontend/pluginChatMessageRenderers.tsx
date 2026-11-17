import type { ComponentType, ReactNode } from "react"
import type { ChatMessageItem, ChatPayload } from "./api/chats"
import type { ChatQueryKey } from "./routes/chat/constants"
import { withPluginErrorBoundary } from "./components/PluginErrorBoundary"
import { getPluginContribution } from "./pluginContributionRegistry"
import "./builtInPluginContributions"

export type PluginChatMessagePresentation = { component: string; data?: unknown }
export type PluginChatMessageProps = {
  item: ChatMessageItem
  payload: ChatPayload
  presentation: PluginChatMessagePresentation
  prefix: string
  queryKey: ChatQueryKey
  readOnly: boolean
  entranceClass: string
  onNotice: (message: string | null) => void
}

type PluginModule = { default?: ComponentType<PluginChatMessageProps> }

export function pluginChatMessageComponentFor(key: string | null | undefined) {
  if (!key) return null
  const [pluginName, componentKey] = key.split("/", 2)
  const value = getPluginContribution<PluginModule>("chat_message_renderer", pluginName, componentKey)?.value
  return value && typeof value !== "function" && value.default ? withPluginErrorBoundary(pluginName, value.default) : null
}

export function renderPluginChatMessage(props: PluginChatMessageProps, fallback: ReactNode = null) {
  const Component = pluginChatMessageComponentFor(props.presentation.component)
  return Component ? <Component {...props} /> : fallback
}
