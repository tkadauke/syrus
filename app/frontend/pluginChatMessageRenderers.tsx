import type { ComponentType, ReactNode } from "react"
import { useTranslation } from "react-i18next"
import type { ChatMessageItem, ChatPayload } from "./api/chats"
import { pluginNamespacesFor } from "./i18n"
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
const modules = import.meta.glob<PluginModule>(
  ["../../plugins/*/app/frontend/chat_message_renderers/*.tsx", "!../../plugins/*/app/frontend/chat_message_renderers/*.test.tsx"],
  { eager: true }
)
const pattern = /^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/chat_message_renderers\/([^/.]+)\.tsx$/
const components = Object.fromEntries(
  Object.entries(modules).flatMap(([path, module]) => {
    const match = path.match(pattern)
    return match && module.default ? [[`${match[1]}/${match[2]}`, module.default]] : []
  })
) as Record<string, ComponentType<PluginChatMessageProps>>

export function pluginChatMessageComponentFor(key: string | null | undefined) {
  return key ? components[key] || null : null
}

export function renderPluginChatMessage(props: PluginChatMessageProps, fallback: ReactNode = null) {
  const Component = pluginChatMessageComponentFor(props.presentation.component)
  if (!Component) return fallback

  const plugin = props.presentation.component.split("/")[0]
  return <PluginChatMessage Component={Component} plugin={plugin} props={props} />
}

// Renderers are bundled eagerly, so nothing loads their plugin's translations
// before they mount. A renderer calling useTranslation for its namespace would
// then suspend -- and when that render is a synchronous update, such as a live
// message arriving, React throws #426 and the chat page errors out. Load the
// namespaces here without suspending and show the plain message until they are
// ready.
function PluginChatMessage({
  Component,
  plugin,
  props
}: {
  Component: ComponentType<PluginChatMessageProps>
  plugin: string
  props: PluginChatMessageProps
}) {
  const { ready } = useTranslation(pluginNamespacesFor(plugin), { useSuspense: false })
  if (!ready) {
    return (
      <article aria-busy="true" className="whitespace-pre-wrap py-2 text-sm text-text-muted" data-plugin-message-loading={plugin}>
        {props.item.text}
      </article>
    )
  }

  return <Component {...props} />
}
