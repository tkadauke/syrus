import type { ComponentType, ReactNode } from "react"
import type { ChatMessageItem, ChatPayload } from "./api/chats"
import type { ChatQueryKey } from "./routes/chat/constants"

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
const modules = import.meta.glob<PluginModule>(["../../plugins/*/app/frontend/chat_message_renderers/*.tsx", "!../../plugins/*/app/frontend/chat_message_renderers/*.test.tsx"], { eager: true })
const pattern = /^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/chat_message_renderers\/([^/.]+)\.tsx$/
const components = Object.fromEntries(Object.entries(modules).flatMap(([path, module]) => {
  const match = path.match(pattern)
  return match && module.default ? [[`${match[1]}/${match[2]}`, module.default]] : []
})) as Record<string, ComponentType<PluginChatMessageProps>>

export function pluginChatMessageComponentFor(key: string | null | undefined) {
  return key ? components[key] || null : null
}

export function renderPluginChatMessage(props: PluginChatMessageProps, fallback: ReactNode = null) {
  const Component = pluginChatMessageComponentFor(props.presentation.component)
  return Component ? <Component {...props} /> : fallback
}
