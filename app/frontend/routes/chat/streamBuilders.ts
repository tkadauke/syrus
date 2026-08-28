// Message-stream builder helpers extracted from Chat.tsx.
//
// Turn the raw message list + pending actions into the ordered render stream:
// build the item list, inject timestamp/day-divider markers, transform a
// single message into its render item (delegating tool/system messages to the
// systemMessages parsers), and the small grouping/anchor predicates. Pure over
// the shared utils, systemMessages, and chat types; imported back by the
// MessageStream components.
import type { ChatMessageItem, ChatPendingAction, ChatPendingActionInline, ChatRenderItem, ChatToolGroupCall, ChatToolGroupItem } from "../../api/chats"
import type { ChatStreamItem } from "./streamTypes"
import { contentInput, contentRecord, dayDividerLabel, sameLocalDay } from "./utils"
import { structuredTool, systemMessage } from "./systemMessages"
import { fullResultBody, shortenWorkspacePaths, simpleToolProgressLabel, toolDetail, toolLabel, toolResultSummary } from "./toolRendering"

// Groups are tracked per "parent" tool_use id rather than a single global
// "last open group": a nested Agent/Task call's own tool_use/tool_result
// pair interleaves with the still-open outer call, so pairing by adjacency
// alone (the pre-EPIC-240 behavior) orphaned the outer group. ROOT_KEY is
// the bucket for calls with no parent (message.parent_tool_use_id unset).
const ROOT_KEY = "\0root"

type OpenCall = {
  call: ChatToolGroupCall
  group: ChatToolGroupItem
  container: ChatRenderItem[]
}

export function renderChatMessages(messages: ChatMessageItem[], options: { simpleMode?: boolean } = {}): ChatRenderItem[] {
  const items: ChatRenderItem[] = []
  const containerByParentKey = new Map<string, ChatRenderItem[]>([ [ ROOT_KEY, items ] ])
  const lastGroupByParentKey = new Map<string, ChatToolGroupItem | null>([ [ ROOT_KEY, null ] ])
  const openCallsByToolUseId = new Map<string, OpenCall>()

  for (const message of messages) {
    if (groupableToolUse(message)) {
      const toolName = message.tool_name || ""
      const tool = toolLabel(toolName)
      const parentKey = message.parent_tool_use_id && containerByParentKey.has(message.parent_tool_use_id) ? message.parent_tool_use_id : ROOT_KEY
      const container = containerByParentKey.get(parentKey) as ChatRenderItem[]
      const call: ChatToolGroupCall = {
        message_id: message.id,
        detail: toolDetail(toolName, contentInput(message.content)),
        progress_label: simpleToolProgressLabel(toolName),
        result_body: "",
        result_error: false,
        result_summary: "",
        nested: []
      }

      const lastGroup = lastGroupByParentKey.get(parentKey) ?? null
      let group: ChatToolGroupItem
      if (lastGroup !== null && lastGroup.tool === tool) {
        lastGroup.calls.push(call)
        group = lastGroup
      } else {
        group = { type: "tool_group", tool, calls: [ call ] }
        container.push(group)
        lastGroupByParentKey.set(parentKey, group)
      }

      const toolUseId = toolUseIdFor(message)
      if (toolUseId) {
        openCallsByToolUseId.set(toolUseId, { call, group, container })
        containerByParentKey.set(toolUseId, call.nested!)
        lastGroupByParentKey.set(toolUseId, null)
      }
    } else if (groupableToolResult(message)) {
      const refId = toolResultRefIdFor(message)
      let open = refId ? openCallsByToolUseId.get(refId) : undefined
      if (!open && !refId) {
        // No tool_use_id on the result content to key off of (older data
        // predating id-based tagging) -- fall back to the pre-nesting
        // behavior of pairing with the most recently opened call at the
        // same level.
        const parentKey = message.parent_tool_use_id && containerByParentKey.has(message.parent_tool_use_id) ? message.parent_tool_use_id : ROOT_KEY
        const lastGroup = lastGroupByParentKey.get(parentKey) ?? null
        const lastCall = lastGroup?.calls.at(-1)
        if (lastGroup && lastCall) open = { call: lastCall, group: lastGroup, container: containerByParentKey.get(parentKey)! }
      }

      if (open && open.call.result_body === "") {
        const content = contentRecord(message.content)
        open.call.result_body = shortenWorkspacePaths(content ? fullResultBody(content.content ?? content.result) : String(message.content ?? message.text))
        open.call.result_error = content?.is_error === true
        open.call.result_summary = toolResultSummary(open.group.tool, open.call.result_body)
        if (options.simpleMode && !open.call.result_error) {
          open.group.calls = open.group.calls.filter((call) => call !== open.call)
          if (open.group.calls.length === 0) {
            const index = open.container.indexOf(open.group)
            if (index !== -1) open.container.splice(index, 1)
          }
        }
      } else {
        resetLastGroup(message, lastGroupByParentKey)
        const item = renderMessage(message, options)
        if (item) items.push(item)
      }
    } else {
      resetLastGroup(message, lastGroupByParentKey)
      const item = renderMessage(message, options)
      if (item) items.push(item)
    }
  }

  return items
}

function resetLastGroup(message: ChatMessageItem, lastGroupByParentKey: Map<string, ChatToolGroupItem | null>) {
  const parentKey = message.parent_tool_use_id && lastGroupByParentKey.has(message.parent_tool_use_id) ? message.parent_tool_use_id : ROOT_KEY
  lastGroupByParentKey.set(parentKey, null)
}

function toolUseIdFor(message: ChatMessageItem) {
  const id = contentRecord(message.content)?.id
  return typeof id === "string" && id.length > 0 ? id : null
}

function toolResultRefIdFor(message: ChatMessageItem) {
  const id = contentRecord(message.content)?.tool_use_id
  return typeof id === "string" && id.length > 0 ? id : null
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
    execution_status: action.execution_status,
    execution_step: action.execution_step,
    execution_error: action.execution_error,
    resource_title: action.resource_title,
    resource_url: action.resource_url,
    app_confirm_path: action.app_confirm_path,
    app_reject_path: action.app_reject_path,
    app_cancel_path: action.app_cancel_path
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
