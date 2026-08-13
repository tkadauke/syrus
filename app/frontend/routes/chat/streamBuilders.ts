// Message-stream builder helpers extracted from Chat.tsx.
//
// Turn the raw message list + pending actions into the ordered render stream:
// build the item list, inject timestamp/day-divider markers, transform a
// single message into its render item (delegating tool/system messages to the
// systemMessages parsers), and the small grouping/anchor predicates. Pure over
// the shared utils, systemMessages, and chat types; imported back by the
// MessageStream components.
import type { ChatMessageItem, ChatPendingAction, ChatPendingActionInline, ChatRenderItem, ChatToolGroupItem } from "../../api/chats"
import type { ChatStreamItem } from "./streamTypes"
import { contentInput, contentRecord, dayDividerLabel, sameLocalDay } from "./utils"
import { structuredTool, systemMessage } from "./systemMessages"
import { fullResultBody, shortenWorkspacePaths, simpleToolProgressLabel, toolDetail, toolLabel, toolResultSummary } from "./toolRendering"

export function renderChatMessages(messages: ChatMessageItem[], options: { simpleMode?: boolean } = {}): ChatRenderItem[] {
  const items: ChatRenderItem[] = []
  let currentGroup: ChatToolGroupItem | null = null

  for (const message of messages) {
    if (groupableToolUse(message)) {
      const toolName = message.tool_name || ""
      const call = {
        message_id: message.id,
        detail: toolDetail(toolName, contentInput(message.content)),
        progress_label: simpleToolProgressLabel(toolName),
        result_body: "",
        result_error: false,
        result_summary: ""
      }
      const tool = toolLabel(toolName)
      if (currentGroup !== null && currentGroup.tool === tool) {
        currentGroup.calls.push(call)
      } else {
        currentGroup = { type: "tool_group", tool, calls: [call] }
        items.push(currentGroup)
      }
    } else if (groupableToolResult(message)) {
      const lastCall = currentGroup?.calls.at(-1)
      if (lastCall && lastCall.result_body === "") {
        const content = contentRecord(message.content)
        lastCall.result_body = shortenWorkspacePaths(content ? fullResultBody(content.content ?? content.result) : String(message.content ?? message.text))
        lastCall.result_error = content?.is_error === true
        lastCall.result_summary = toolResultSummary(currentGroup?.tool || "", lastCall.result_body)
        if (options.simpleMode && !lastCall.result_error && currentGroup) {
          currentGroup.calls.pop()
          if (currentGroup.calls.length === 0) {
            items.pop()
            currentGroup = null
          }
        }
      } else {
        currentGroup = null
        const item = renderMessage(message, options)
        if (item) items.push(item)
      }
    } else {
      currentGroup = null
      const item = renderMessage(message, options)
      if (item) items.push(item)
    }
  }

  return items
}

export function lastAssistantRenderedMessage(messages: ChatMessageItem[]) {
  const items = renderChatMessages(messages)
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const item = items[index]
    if (item.type === "message" && item.role === "assistant") return item
  }

  return null
}

export function buildMessageStreamItems(items: ChatRenderItem[], pendingActions: ChatPendingAction[]): ChatStreamItem[] {
  if (pendingActions.length === 0) return items

  const actionsByMessageId = new Map<number, ChatPendingAction[]>()
  const unanchoredActions: ChatPendingAction[] = []
  const renderedMessageIds = new Set<number>()
  const result: ChatStreamItem[] = []

  for (const action of pendingActions) {
    const messageId = action.chat_message_id
    if (messageId == null) {
      unanchoredActions.push(action)
      continue
    }

    const actions = actionsByMessageId.get(messageId) || []
    actions.push(action)
    actionsByMessageId.set(messageId, actions)
  }

  for (const item of items) {
    result.push(item)

    const messageIds = streamItemMessageIds(item)
    for (const messageId of messageIds) {
      renderedMessageIds.add(messageId)
      const actions = actionsByMessageId.get(messageId) || []
      for (const action of actions) {
        result.push({ type: "pending_action", pendingAction: action })
      }
    }
  }

  for (const [messageId, actions] of actionsByMessageId) {
    if (renderedMessageIds.has(messageId)) continue
    unanchoredActions.push(...actions)
  }

  for (const action of unanchoredActions) {
    result.push({ type: "pending_action", pendingAction: action })
  }

  return result
}

export function injectTemporalMarkers(items: ChatStreamItem[]): ChatStreamItem[] {
  const result: ChatStreamItem[] = []
  let lastMessageDate: Date | null = null

  for (const item of items) {
    if (item.type === "message" && temporalAnchorRole(item.role) && item.created_at) {
      const messageDate = new Date(item.created_at)
      if (!Number.isNaN(messageDate.getTime())) {
        if (lastMessageDate === null || !sameLocalDay(messageDate, lastMessageDate)) {
          result.push({
            type: "day_divider",
            date: item.created_at,
            label: dayDividerLabel(messageDate)
          })
        }

        if (lastMessageDate === null || messageDate.getTime() - lastMessageDate.getTime() >= 5 * 60 * 1000) {
          result.push({
            type: "timestamp",
            time: messageDate.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" }),
            fullDatetime: messageDate.toLocaleString()
          })
        }

        lastMessageDate = messageDate
      }
    }

    result.push(item)
  }

  return result
}

export function temporalAnchorRole(role: ChatMessageItem["role"]) {
  return role === "user" || role === "assistant"
}

export function streamItemMessageIds(item: ChatRenderItem) {
  if (item.type === "message") return [item.id]
  return item.calls.map((call) => call.message_id)
}

export function pendingActionCardData(action: ChatPendingAction): ChatPendingActionInline {
  return {
    id: action.id,
    action: action.action || action.action_type,
    state: action.state,
    label: action.label,
    detail: action.detail,
    resource_title: action.resource_title,
    resource_url: action.resource_url,
    app_confirm_path: action.app_confirm_path,
    app_reject_path: action.app_reject_path
  }
}

export function renderMessage(message: ChatMessageItem, options: { simpleMode?: boolean } = {}): ChatRenderItem | null {
  if (message.role === "system") {
    const system = systemMessage(message)
    if (system === null) return null

    return { ...message, system }
  }

  if (message.role === "tool_use" || message.role === "tool_result") {
    if (options.simpleMode) return null

    return { ...message, tool: structuredTool(message) }
  }

  return message
}

export function groupableToolUse(message: ChatMessageItem) {
  return message.role === "tool_use" && Boolean(message.tool_name) && !message.proposal
}

export function groupableToolResult(message: ChatMessageItem) {
  return message.role === "tool_result" && !message.proposal
}
