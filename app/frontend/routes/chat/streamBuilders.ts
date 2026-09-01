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
import { fullResultBody, shortenWorkspacePaths, simpleToolProgressLabel, toolPresentation, toolResultPresentation } from "./toolRendering"

// Groups are tracked per "parent" tool_use id rather than a single global
// "last open group": a nested Agent/Task call's own tool_use/tool_result
// pair interleaves with the still-open outer call, so pairing by adjacency
// alone (the pre-EPIC-240 behavior) orphaned the outer group. ROOT_KEY is
// the bucket for calls with no parent (message.parent_tool_use_id unset).
const ROOT_KEY = "\0root"
const INSPECTION_GROUP_KEY = "\0inspection"

type ToolVisibility = "inspection" | "normal" | "prominent"

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
      const presentation = toolPresentation(toolName, contentInput(message.content))
      const tool = presentation.display_label
      const visibility = toolVisibility(presentation.name)
      const parentKey = message.parent_tool_use_id && containerByParentKey.has(message.parent_tool_use_id) ? message.parent_tool_use_id : ROOT_KEY
      const container = containerByParentKey.get(parentKey) as ChatRenderItem[]
      const call: ChatToolGroupCall = {
        message_id: message.id,
        tool_name: presentation.name,
        raw_name: presentation.raw_name,
        detail: presentation.argument_summary,
        display_label: presentation.display_label,
        progress_label: simpleToolProgressLabel(toolName),
        raw_payload: presentation.raw_payload,
        result_body: "",
        result_error: false,
        result_kind: "unknown",
        result_summary: "",
        nested: []
      }

      const lastGroup = lastGroupByParentKey.get(parentKey) ?? null
      const groupKey = visibility === "inspection" ? INSPECTION_GROUP_KEY : tool
      let group: ChatToolGroupItem
      if (lastGroup !== null && groupIdentity(lastGroup) === groupKey) {
        lastGroup.calls.push(call)
        group = lastGroup
      } else {
        group = { type: "tool_group", tool, calls: [ call ] }
        if (visibility === "inspection") group.group_key = INSPECTION_GROUP_KEY
        if (visibility === "prominent") group.prominent = true
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
        const resultPresentation = toolResultPresentation(open.call.tool_name, open.call.result_body, open.call.result_error)
        open.call.result_kind = resultPresentation.kind
        open.call.result_summary = resultPresentation.summary
        open.call.summary_metadata = resultPresentation.metadata
        updateToolGroupPresentation(open.group)
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
      if (message.role === "assistant" && message.text.trim().length > 0) collapsePrecedingToolGroups(items)
      resetLastGroup(message, lastGroupByParentKey)
      const item = renderMessage(message, options)
      if (item) items.push(item)
    }
  }

  return items
}

function groupIdentity(group: ChatToolGroupItem) {
  return group.group_key || group.tool
}

function collapsePrecedingToolGroups(items: ChatRenderItem[]) {
  for (const item of items) {
    if (item.type !== "tool_group") continue

    markCollapsedAfterAssistant(item)
  }
}

function markCollapsedAfterAssistant(group: ChatToolGroupItem) {
  updateToolGroupPresentation(group)
  group.collapsed_by_default = !group.prominent
  for (const call of group.calls) {
    for (const nested of call.nested || []) {
      markCollapsedAfterAssistant(nested)
    }
  }
}

function updateToolGroupPresentation(group: ChatToolGroupItem) {
  const failed = group.calls.some((call) => call.result_error)
  const pending = group.calls.some((call) => call.result_kind === "unknown" && !call.result_body)
  const sideEffecting = group.calls.some((call) => toolVisibility(call.tool_name) === "prominent")
  group.prominent = failed || pending || sideEffecting
  group.outcome_label = groupOutcomeLabel(group, { failed, pending })
  group.summary_label = group.group_key === INSPECTION_GROUP_KEY ? inspectionSummaryLabel(group) : group.tool
}

function groupOutcomeLabel(group: ChatToolGroupItem, state: { failed: boolean; pending: boolean }) {
  if (state.failed) return "Needs attention"
  if (state.pending) return "Running"

  const aggregate = aggregateResultMetadata(group)
  if (aggregate) return aggregate
  if (group.calls.length > 1) return `${group.calls.length} calls`

  return group.calls[0]?.result_summary || "Completed"
}

function aggregateResultMetadata(group: ChatToolGroupItem) {
  const nouns = new Map<string, number>()
  for (const call of group.calls) {
    const count = call.summary_metadata?.count
    const noun = call.summary_metadata?.noun
    if (typeof count === "number" && typeof noun === "string") nouns.set(noun, (nouns.get(noun) || 0) + count)
  }

  if (nouns.size !== 1) return null

  const [noun, count] = Array.from(nouns.entries())[0]
  return `${count} ${pluralizedNoun(noun, count)}`
}

function pluralizedNoun(noun: string, count: number) {
  if (count === 1 || noun.endsWith("s")) return noun
  if (noun.endsWith("ch")) return `${noun}es`

  return `${noun}s`
}

function inspectionSummaryLabel(group: ChatToolGroupItem) {
  return `Inspected ${group.calls.length} source${group.calls.length === 1 ? "" : "s"}`
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

function toolVisibility(name: string): ToolVisibility {
  if (readOnlyTool(name)) return "inspection"
  if (sideEffectingTool(name)) return "prominent"

  return "normal"
}

function readOnlyTool(name: string) {
  const normalized = name.toLowerCase()

  return [
    "read",
    "glob",
    "grep",
    "ls",
    "webfetch",
    "websearch",
    "toolsearch",
    "read_live_state",
    "read_memory",
    "search_memories",
    "list_memories",
    "list_chat_media",
    "read_design_doc",
    "list_design_docs"
  ].includes(normalized) || /^(read|get|list|search|find|fetch|inspect|resolve)_/.test(normalized)
}

function sideEffectingTool(name: string) {
  const normalized = name.toLowerCase()

  return [
    "bash",
    "edit",
    "multiedit",
    "write",
    "notebookedit",
    "todowrite"
  ].includes(normalized) || /^(write|create|update|delete|submit|propose|confirm|reject|cancel|archive|start|move|add|remove|edit)_/.test(normalized)
}
