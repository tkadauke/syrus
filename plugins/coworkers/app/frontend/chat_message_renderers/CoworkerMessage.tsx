import type { CSSProperties } from "react"
import { Link } from "react-router-dom"
import { Avatar } from "@app/components/Avatar"
import { useT } from "@app/hooks/useT"
import { useLongPressMenu } from "@app/hooks/useLongPressMenu"
import { accentRamp } from "@app/lib/appearance"
import type { PluginChatMessageProps } from "@app/pluginChatMessageRenderers"
import {
  ChatAssistantMarkdownSurface,
  MessageActions,
  MessageFileAttachments,
  MessageImageAttachments,
  SharedMessageRenderer
} from "@app/routes/chat/MessageCards"
import { withRoutePrefix } from "@app/routes/chat/utils"

type Appearance = { name: string; handle?: string; accent_hex: string; avatar_key: string | null; avatar_url: string | null }
type Presentation = { appearance?: Appearance | null; direction?: "incoming" | "outgoing"; handle?: string; working_session_id?: number }

export function withoutMessagePrefix(text: string, direction: "from" | "to", handle?: string) {
  if (!handle) return text
  const prefix = `Message ${direction} @${handle}`
  return text === prefix ? "" : text.startsWith(`${prefix}\n\n`) ? text.slice(prefix.length + 2) : text
}

export default function CoworkerMessage({ item, payload, presentation, prefix, queryKey, readOnly, entranceClass, onNotice }: PluginChatMessageProps) {
  const { t } = useT("coworkers")
  const data = (presentation.data || {}) as Presentation
  const outgoing = data.direction === "outgoing"
  const direction = outgoing ? "to" : "from"
  const text = withoutMessagePrefix(item.text, direction, data.handle)
  const appearance = data.appearance
  const messageMenu = useLongPressMenu(!readOnly && !!item.text)
  const colors = appearance ? accentRamp(appearance.accent_hex) : null
  const label = appearance?.name || (data.handle ? `@${data.handle}` : "—")
  const accentStyle = colors
    ? ({ backgroundColor: `color-mix(in srgb, var(--color-surface) 88%, ${colors.solid})`, borderLeftColor: colors.solid } as CSSProperties)
    : undefined

  return (
    <SharedMessageRenderer animateClass={entranceClass} id={`chat_message_${item.id}`} readOnly={readOnly} targetProps={messageMenu.targetProps}>
      <span className="absolute -top-4" id={`message-${item.id}`} />
      {readOnly ? null : <MessageActions item={item} payload={payload} queryKey={queryKey} onNotice={onNotice} menu={messageMenu} />}
      <div
        className={`min-w-0 space-y-2 rounded-r border-l-4 p-4 text-text-primary ${colors ? "" : "border-border bg-surface-subtle"}`}
        style={accentStyle}
        data-testid={outgoing ? "coworker-outgoing-message" : "coworker-incoming-message"}
      >
        <div className="flex min-w-0 items-center gap-2 text-xs font-medium">
          <Avatar avatarUrl={appearance?.avatar_url} avatarKey={appearance?.avatar_key} accentHex={appearance?.accent_hex} name={label} size="xs" />
          <span className="truncate">{label}</span>
          {outgoing && data.handle ? <span className="truncate font-normal text-text-muted">{t("chat.message_to", { handle: data.handle })}</span> : null}
        </div>
        {data.working_session_id ? (
          <Link className="inline-block text-xs text-text-muted underline hover:no-underline" to={withRoutePrefix(`/chats/${data.working_session_id}`, prefix)}>
            {t("chat.view_working_session")}
          </Link>
        ) : null}
        {item.cross_chat_bridge?.direction === "inbound" ? (
          <div className="flex items-center gap-2 text-xs font-normal text-text-muted" data-testid="cross-chat-bridge-chip">
            <span aria-hidden="true">🔗</span>
            <Link
              className="truncate underline hover:no-underline"
              to={withRoutePrefix(`/chats/${item.cross_chat_bridge.counterpart_chat_session_id}`, prefix)}
            >
              {t("chat.bridge_link", {
                id: item.cross_chat_bridge.counterpart_chat_session_id,
                title: item.cross_chat_bridge.counterpart_chat_title || t("chat.new_title")
              })}
            </Link>
          </div>
        ) : null}
        {text.trim() ? <ChatAssistantMarkdownSurface text={text} /> : null}
        <MessageImageAttachments attachments={item.attachments} />
        <MessageFileAttachments attachments={item.attachments} />
      </div>
    </SharedMessageRenderer>
  )
}
