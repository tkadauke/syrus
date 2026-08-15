// Groups raw ClaudeTranscript events (tool_use/tool_result pairs, plus the
// surrounding text/system events) into the same ChatToolGroupItem shape the
// chat transcript renderer already knows how to draw (MessageCards.tsx's
// ToolGroup), so the admin Run transcript can reuse that component instead of
// re-rendering every tool_use/tool_result as its own unrelated flat card.
import type { ChatToolGroupItem } from "../api/chats"
import type { TranscriptEvent } from "../api/adminTranscript"
import { fullResultBody, simpleToolProgressLabel, toolDetail, toolLabel, toolResultSummary } from "./chat/toolRendering"
import { stringValue } from "./chat/utils"

export type AdminTranscriptToolGroupItem = ChatToolGroupItem & { key: string }
export type AdminTranscriptTextItem = { type: "text"; kind: "user_prompt" | "assistant_text" | "job_log"; text: string; key: string }
export type AdminTranscriptInitItem = { type: "system_init"; data: Record<string, unknown>; key: string }
export type AdminTranscriptResultItem = { type: "result"; data: Record<string, unknown>; key: string }
export type AdminTranscriptFallbackItem = { type: "fallback"; badge: string; title: string | null; data: unknown; tone: "gray" | "red" | "emerald"; key: string }

export type AdminTranscriptRenderItem =
  | AdminTranscriptToolGroupItem
  | AdminTranscriptTextItem
  | AdminTranscriptInitItem
  | AdminTranscriptResultItem
  | AdminTranscriptFallbackItem

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function preview(value: unknown) {
  return stringValue(typeof value === "string" ? value : JSON.stringify(value)).replace(/\s+/g, " ").slice(0, 150)
}

// Pairs tool_result events back to their tool_use call by id (Claude's
// `id`/`tool_use_id`, Codex's `call_id`) rather than by stream adjacency,
// since parallel tool calls interleave multiple tool_use blocks before any
// of their results arrive. Pairing only works within the events passed in —
// a tool_use split across a pagination boundary from its tool_result renders
// as an unmatched call (no result) / orphan result, same as before this
// grouping existed.
export function groupTranscriptEvents(events: TranscriptEvent[]): AdminTranscriptRenderItem[] {
  const items: AdminTranscriptRenderItem[] = []
  let currentGroup: AdminTranscriptToolGroupItem | null = null
  const openCalls = new Map<string, { tool: string; call: AdminTranscriptToolGroupItem["calls"][number] }>()

  events.forEach((event, index) => {
    const data = event.data || {}

    if (event.kind === "tool_use") {
      const name = stringValue(data.name)
      const tool = toolLabel(name)
      const call = {
        message_id: index,
        detail: toolDetail(name, isRecord(data.input) ? data.input : {}),
        progress_label: simpleToolProgressLabel(name),
        result_body: "",
        result_error: false,
        result_summary: ""
      }

      if (currentGroup && currentGroup.tool === tool) {
        currentGroup.calls.push(call)
      } else {
        currentGroup = { type: "tool_group", tool, calls: [call], key: `group-${index}` }
        items.push(currentGroup)
      }

      const id = data.id
      if (id != null) openCalls.set(String(id), { tool, call })
      return
    }

    if (event.kind === "tool_result") {
      const toolUseId = data.tool_use_id
      const open = toolUseId != null ? openCalls.get(String(toolUseId)) : undefined

      if (open) {
        const body = fullResultBody(data.content)
        open.call.result_body = body
        open.call.result_error = data.error === true
        open.call.result_summary = toolResultSummary(open.tool, body)
        return
      }

      currentGroup = null
      items.push({
        type: "fallback",
        badge: data.error === true ? "tool err" : "tool ok",
        title: preview(data.content),
        data: data.content,
        tone: data.error === true ? "red" : "emerald",
        key: `event-${index}`
      })
      return
    }

    currentGroup = null

    if (event.kind === "user_prompt") {
      items.push({ type: "text", kind: "user_prompt", text: stringValue(data.text), key: `event-${index}` })
    } else if (event.kind === "assistant_text") {
      items.push({ type: "text", kind: "assistant_text", text: stringValue(data.text), key: `event-${index}` })
    } else if (event.kind === "job_log") {
      items.push({ type: "text", kind: "job_log", text: stringValue(data.text), key: `event-${index}` })
    } else if (event.kind === "system_init") {
      items.push({ type: "system_init", data, key: `event-${index}` })
    } else if (event.kind === "result") {
      items.push({ type: "result", data, key: `event-${index}` })
    } else {
      items.push({ type: "fallback", badge: event.kind, title: null, data, tone: "gray", key: `event-${index}` })
    }
  })

  return items
}
