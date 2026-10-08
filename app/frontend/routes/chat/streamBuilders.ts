// Message-stream builder helpers extracted from Chat.tsx.
//
// Turn the raw message list + pending actions into the ordered render stream:
// build the item list, inject timestamp/day-divider markers, transform a
// single message into its render item (delegating tool/system messages to the
// systemMessages parsers), and the small grouping/anchor predicates. Pure over
// the shared utils, systemMessages, and chat types; imported back by the
// MessageStream components.
import type { ChatMessageItem, ChatPendingAction, ChatPendingActionGroup, ChatPendingActionInline, ChatRenderItem, ChatToolGroupCall, ChatToolGroupItem } from "../../api/chats"
import type { ChatStreamItem } from "./streamTypes"
import { contentInput, contentRecord, dayDividerLabel, sameLocalDay } from "./utils"
import { structuredTool, systemMessage } from "./systemMessages"
import { NO_ARGUMENTS_SENTINEL, fullResultBody, fullResultBodyUnbounded, isPlainObject, parsedToolResult, shortenWorkspacePaths, simpleToolProgressLabel, toolPresentation, toolResultPresentation } from "./toolRendering"
import { isReadOnlyToolName } from "../../toolPresentationRegistry"

// Groups are tracked per "parent" tool_use id rather than a single global
// "last open group": a nested Agent/Task call's own tool_use/tool_result
// pair interleaves with the still-open outer call, so pairing by adjacency
// alone (the previous behavior) orphaned the outer group. ROOT_KEY is
// the bucket for calls with no parent (message.parent_tool_use_id unset).
const ROOT_KEY = "\0root"

type OpenCall = {
  call: ChatToolGroupCall
  group: ChatToolGroupItem
  container: ChatRenderItem[]
}

export function renderChatMessages(messages: ChatMessageItem[]): ChatRenderItem[] {
  const items: ChatRenderItem[] = []
  const containerByParentKey = new Map<string, ChatRenderItem[]>([ [ ROOT_KEY, items ] ])
  const lastGroupByParentKey = new Map<string, ChatToolGroupItem | null>([ [ ROOT_KEY, null ] ])
  const openCallsByToolUseId = new Map<string, OpenCall>()

  for (const message of messages) {
    if (groupableToolUse(message)) {
      const toolName = message.tool_name || ""
      const presentation = toolPresentation(toolName, contentInput(message.content))
      const tool = presentation.display_label
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
        result_settled: false,
        result_error: false,
        result_kind: "unknown",
        result_summary: "",
        // ChatPendingAction::anchor_to_tool_call! always anchors onto the
        // tool_use message, never the paired tool_result -- so this is the
        // only message carrying a live pending_action for the whole call.
        // Seeded here (rather than left to the tool_result settle branch
        // below) so it's available even before the result arrives, and so a
        // tool_result message that never carries pending_action doesn't
        // clobber it back to null.
        pending_action: message.pending_action ?? null,
        nested: []
      }

      const lastGroup = lastGroupByParentKey.get(parentKey) ?? null
      let group: ChatToolGroupItem
      if (lastGroup !== null && canJoinToolGroup(lastGroup, presentation.name, tool)) {
        lastGroup.calls.push(call)
        group = lastGroup
      } else {
        group = { type: "tool_group", tool, calls: [ call ] }
        container.push(group)
        lastGroupByParentKey.set(parentKey, group)
      }
      updateToolGroupState(group)

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

      if (open && open.call.result_settled !== true) {
        const content = contentRecord(message.content)
        const rawResult = content ? content.content ?? content.result : message.content ?? message.text
        const unboundedBody = content ? fullResultBodyUnbounded(rawResult) : shortenWorkspacePaths(String(rawResult))
        open.call.result_body = content ? fullResultBody(rawResult) : unboundedBody
        const parsedResult = parsedToolResult(rawResult, unboundedBody)
        open.call.result_json = parsedResult
        open.call.result_settled = true
        open.call.result_error = content?.is_error === true
        open.call.result_benign_cleanup = content?.benign_cleanup === true
        // The tool_result message itself essentially never carries its own
        // pending_action (anchoring happens on the tool_use message above),
        // but prefer it if some future call shape does -- otherwise keep
        // whatever the tool_use message already seeded.
        open.call.pending_action = message.pending_action ?? open.call.pending_action ?? null
        const resultPresentation = toolResultPresentation(
          open.call.tool_name,
          open.call.result_body,
          open.call.result_error,
          unboundedBody,
          isPlainObject(open.call.raw_payload) ? open.call.raw_payload : {},
          parsedResult
        )
        open.call.result_kind = resultPresentation.kind
        open.call.result_summary = resultPresentation.summary
        open.call.summary_metadata = resultPresentation.metadata
        updateToolGroupState(open.group)
      } else {
        resetLastGroup(message, lastGroupByParentKey)
        const item = renderMessage(message)
        if (item) items.push(item)
      }
    } else {
      resetLastGroup(message, lastGroupByParentKey)
      const item = renderMessage(message)
      if (item?.type === "message" && item.role === "assistant") collapseSettledToolGroups(items)
      if (item) items.push(item)
    }
  }

  return pruneBenignDanglingToolGroups(items)
}

function updateToolGroupState(group: ChatToolGroupItem) {
  const calls = group.calls
  const failed = calls.some((call) => call.result_error)
  const pendingSideEffect = calls.some((call) => !toolCallSettled(call) && !readOnlyTool(call.tool_name))
  const sideEffecting = calls.some((call) => sideEffectingTool(call.tool_name))
  group.prominent = failed || pendingSideEffect || sideEffecting
  group.collapsed_by_default = true
  group.outcome_label = failed ? "Failed" : calls.some((call) => !toolCallSettled(call)) ? "Running" : "Done"

  if (calls.length > 1 && calls.every((call) => readOnlyTool(call.tool_name))) {
    group.tool = "Inspection"
    group.summary_label = inspectionSummary(calls)
  } else if (calls.length > 1) {
    group.summary_label = `${calls[0]?.display_label || group.tool} (${calls.length})`
  } else {
    group.summary_label = calls[0]?.display_label || group.tool
  }
}

function toolCallSettled(call: ChatToolGroupCall) {
  return call.result_settled === true || call.result_body !== ""
}

function canJoinToolGroup(group: ChatToolGroupItem, nextToolName: string, nextToolLabel: string) {
  if (group.tool === nextToolLabel) return true
  return readOnlyTool(nextToolName) && group.calls.every((call) => readOnlyTool(call.tool_name))
}

function collapseSettledToolGroups(items: ChatRenderItem[]) {
  for (const item of items) {
    if (item.type !== "tool_group") continue
    collapseSettledToolGroup(item)
  }
}

function collapseSettledToolGroup(group: ChatToolGroupItem) {
  updateToolGroupState(group)

  for (const call of group.calls) {
    for (const nested of call.nested || []) collapseSettledToolGroup(nested)
  }
}

function pruneBenignDanglingToolGroups(items: ChatRenderItem[]): ChatRenderItem[] {
  const result: ChatRenderItem[] = []

  for (const item of items) {
    if (item.type !== "tool_group") {
      result.push(item)
      continue
    }

    const pruned = pruneBenignDanglingToolGroup(item)
    if (pruned) result.push(pruned)
  }

  return result
}

function pruneBenignDanglingToolGroup(group: ChatToolGroupItem): ChatToolGroupItem | null {
  const calls = group.calls.map((call) => ({
    ...call,
    nested: pruneBenignDanglingToolGroups(call.nested || []).filter((item): item is ChatToolGroupItem => item.type === "tool_group")
  })).filter((call) => {
    if (!benignDanglingToolCall(call)) return true

    // Keep the parent wrapper if a nested agent/tool call still has meaningful
    // output; otherwise the synthetic dangling result is terminal bookkeeping.
    return (call.nested || []).length > 0
  })

  if (calls.length === 0) return null

  const pruned = { ...group, calls }
  updateToolGroupState(pruned)
  return pruned
}

function readOnlyTool(name: string) {
  return isReadOnlyToolName(name)
}

function sideEffectingTool(name: string) {
  return !readOnlyTool(name)
}

function inspectionSummary(calls: ChatToolGroupCall[]) {
  const count = calls.length
  const sourceText = count === 1 ? "source" : "sources"
  return count === 1 ? `Inspected ${sourceLabel(calls[0])}` : `Inspected ${count} ${sourceText}`
}

function sourceLabel(call: ChatToolGroupCall | undefined) {
  if (!call) return "source"
  return call.detail && call.detail !== NO_ARGUMENTS_SENTINEL ? call.detail : "source"
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

export function buildMessageStreamItems(items: ChatRenderItem[], pendingActions: ChatPendingAction[], pendingActionGroups: ChatPendingActionGroup[] = []): ChatStreamItem[] {
  if (pendingActions.length === 0 && pendingActionGroups.length === 0) return items

  const anchoredByMessageId = new Map<number, ChatStreamItem[]>()
  const unanchoredItems: ChatStreamItem[] = []
  const renderedMessageIds = new Set<number>()
  const renderedAnchoredItems = new Set<ChatStreamItem>()
  const result: ChatStreamItem[] = []

  const anchor = (messageId: number | null | undefined, streamItem: ChatStreamItem) => {
    if (messageId == null) {
      unanchoredItems.push(streamItem)
      return
    }

    const bucket = anchoredByMessageId.get(messageId) || []
    bucket.push(streamItem)
    anchoredByMessageId.set(messageId, bucket)
  }

  for (const action of pendingActions) anchor(action.chat_message_id, { type: "pending_action", pendingAction: action })
  for (const group of pendingActionGroups) {
    const streamItem: ChatStreamItem = { type: "pending_action_group", pendingActionGroup: group }
    const anchorIds = [ group.chat_message_id, ...group.members.map((member) => member.chat_message_id) ].filter((id): id is number => id != null)
    const uniqueAnchorIds = Array.from(new Set(anchorIds))
    if (uniqueAnchorIds.length === 0) {
      unanchoredItems.push(streamItem)
    } else {
      for (const messageId of uniqueAnchorIds) anchor(messageId, streamItem)
    }
  }

  for (const item of items) {
    result.push(item)

    const messageIds = streamItemMessageIds(item)
    for (const messageId of messageIds) {
      renderedMessageIds.add(messageId)
      for (const anchoredItem of anchoredByMessageId.get(messageId) || []) {
        if (renderedAnchoredItems.has(anchoredItem)) continue

        renderedAnchoredItems.add(anchoredItem)
        result.push(anchoredItem)
      }
    }
  }

  for (const [messageId, anchoredItems] of anchoredByMessageId) {
    if (renderedMessageIds.has(messageId)) continue
    for (const anchoredItem of anchoredItems) {
      if (renderedAnchoredItems.has(anchoredItem)) continue

      renderedAnchoredItems.add(anchoredItem)
      unanchoredItems.push(anchoredItem)
    }
  }

  result.push(...unanchoredItems)

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

export function renderMessage(message: ChatMessageItem): ChatRenderItem | null {
  if (message.role === "system") {
    const system = systemMessage(message)
    if (system === null) return null

    return { ...message, system }
  }

  if (message.role === "tool_use" || message.role === "tool_result") {
    if (benignDanglingToolResultMessage(message)) return null

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

function benignDanglingToolCall(call: ChatToolGroupCall) {
  if (call.result_benign_cleanup === true) return true

  return call.result_error === true && legacyBenignDanglingText(call.result_body)
}

function benignDanglingToolResultMessage(message: ChatMessageItem) {
  if (message.role !== "tool_result") return false

  const content = contentRecord(message.content)
  if (content?.benign_cleanup === true) return true
  if (content?.is_error !== true) return false

  const rawResult = content.content ?? content.result ?? message.content ?? message.text
  return legacyBenignDanglingText(fullResultBodyUnbounded(rawResult))
}

// Only for rows written before ChatDanglingToolCallCloser stamped
// `benign_cleanup`, which is every transcript already in the database --
// dropping it would flood chat history with failed-looking tool cards, the
// very thing this suppression exists to prevent. New reasons must NOT be added
// here: they arrive with the flag set and the checks above see them. These two
// sentences are the only benign ones the closer has ever written.
const LEGACY_BENIGN_DANGLING = /^(?:Cancelled by operator|Agent turn ended) before this tool returned\.?$/i

function legacyBenignDanglingText(text: string) {
  return LEGACY_BENIGN_DANGLING.test(text.trim())
}
