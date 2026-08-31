// Message-display classification/formatting helpers extracted from Chat.tsx.
//
// Pure predicates and formatters over the render items: image-attachment data
// URLs, gathering image attachments, low-priority/proposal-outcome system
// message checks, agent-active detection, counting incoming visible messages,
// mapping a system message to the user text that should be resent on retry,
// and the relative message timestamp. Read only the chat API types plus the
// shared contentRecord util and renderMessage builder.
import type { ChatMessageItem, ChatPayload, ChatRenderItem } from "../../api/chats"
import { contentRecord } from "./utils"
import { renderMessage } from "./streamBuilders"
import { formatRelativeDate, intlLocale } from "../../lib/relativeTime"

export type ChatMessageImageAttachment = { name: string; mime_type: string; data: string }

export function attachmentDataUrl(attachment: ChatMessageImageAttachment) {
  return `data:${attachment.mime_type};base64,${attachment.data}`
}

export function imageAttachments(messages: ChatRenderItem[]) {
  return messages.flatMap((message) => {
    if (message.type !== "message") return []

    return (message.attachments || [])
      .filter((attachment): attachment is ChatMessageImageAttachment => attachment.mime_type.startsWith("image/"))
      .map((attachment, index) => ({ attachment, key: `${message.id}-${attachment.name}-${index}` }))
  })
}

export function isLowPrioritySystemMessage(item: ChatRenderItem) {
  return item.type === "message" &&
    item.role === "system" &&
    !isProposalOutcomeSystemMessage(item) &&
    !isGoalContinuationSystemMessage(item) &&
    ["neutral", "success"].includes(item.system?.tone || "neutral")
}

export function isProposalOutcomeSystemMessage(item: Extract<ChatRenderItem, { type: "message" }>) {
  return contentRecord(item.content)?.source === "proposal_notification"
}

export function isGoalContinuationSystemMessage(item: Extract<ChatRenderItem, { type: "message" }>) {
  const content = contentRecord(item.content)
  return content?.source === "goal_continuation" || content?.goal_continuation === true
}

export function isAgentActive(payload: ChatPayload) {
  return payload.agent_busy || payload.turn_in_flight || payload.switching_provider
}

// The text a "Retry now" button under an error system message should resend:
// the nearest preceding user message, so retrying replays the same turn that
// failed instead of requiring the operator to retype it.
export function retryTextByMessageId(messages: ChatMessageItem[]) {
  const map = new Map<number, string>()
  let lastUserText: string | null = null
  for (const message of messages) {
    if (message.role === "user") {
      lastUserText = message.text
    } else if (message.role === "system" && lastUserText) {
      map.set(message.id, lastUserText)
    }
  }

  return map
}

export function countIncomingVisibleMessages(messages: ChatMessageItem[], previousMaxMessageId: number, showSystemMessages: boolean) {
  return messages.filter((message) => {
    if (message.id <= previousMaxMessageId) return false
    const item = renderMessage(message)
    if (item === null) return false

    return showSystemMessages || !isLowPrioritySystemMessage(item)
  }).length
}

// Chat-bubble timestamp: a hybrid that reads relative for the first 24 hours
// ("5 minutes ago") and flips to an absolute clock/date beyond that (scrollback
// wants the actual time). Both halves respect the viewer's locale — the
// relative side via Intl.RelativeTimeFormat (shared `formatRelativeDate`), the
// absolute side via Intl.DateTimeFormat.
export function formatMessageTimestamp(createdAt: string): string {
  const date = new Date(createdAt)
  const now = new Date()
  const diffHours = (now.getTime() - date.getTime()) / 3_600_000

  if (diffHours < 24) return formatRelativeDate(date, now.getTime())

  const sameYear = date.getFullYear() === now.getFullYear()
  return new Intl.DateTimeFormat(intlLocale(), {
    year: sameYear ? undefined : "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit"
  }).format(date)
}
