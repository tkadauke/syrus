import type { ChatMessageItem, ChatRenderItem } from "../../api/chats"
import { renderChatMessages } from "../chat/streamBuilders"
import type { TranscriptLog } from "./transcript"

const LEGACY_CODEX_COMMAND = /^\[codex command\]\s+(.+?)\s+(in_progress|started|completed|failed)$/i
const LEGACY_CODEX_FILE_IN_PROGRESS = /^\[codex file\].+\s+in_progress$/i

export function transcriptRenderItems(logs: TranscriptLog[]): ChatRenderItem[] {
  const messages: ChatMessageItem[] = []
  const legacyCalls: Array<{ command: string; toolUseId: string }> = []

  for (const log of logs) {
    const structured = structuredMessage(log)
    if (structured) {
      messages.push(structured)
      continue
    }

    const legacyCommand = log.chunk.trim().match(LEGACY_CODEX_COMMAND)
    if (legacyCommand) {
      const [, command, status] = legacyCommand
      if (status === "in_progress" || status === "started") {
        const toolUseId = `legacy-command-${log.id}`
        legacyCalls.push({ command, toolUseId })
        messages.push(toolUseMessage(log, "bash", { command }, toolUseId))
      } else {
        const openIndex = lastLegacyCallIndex(legacyCalls, command)
        if (openIndex >= 0) {
          const [open] = legacyCalls.splice(openIndex, 1)
          messages.push(toolResultMessage(log, open.toolUseId, "", status === "failed"))
        } else {
          messages.push(systemMessage(log))
        }
      }
      continue
    }

    // Codex emits these as transient progress bookkeeping rather than useful
    // conversation content. Completed file changes still remain visible as a
    // quiet log row through the ordinary fallback below.
    if (LEGACY_CODEX_FILE_IN_PROGRESS.test(log.chunk.trim())) continue

    messages.push(log.kind === "assistant_text" ? assistantMessage(log) : systemMessage(log))
  }

  return renderChatMessages(messages)
}

function structuredMessage(log: TranscriptLog): ChatMessageItem | null {
  if (log.kind === "assistant_text") return assistantMessage(log)

  if (log.kind === "tool_call" && log.tool_name) {
    return toolUseMessage(log, log.tool_name, recordInput(log.tool_input), log.tool_use_id || `transcript-${log.id}`)
  }

  if (log.kind === "tool_result" && log.tool_use_id) {
    return toolResultMessage(log, log.tool_use_id, log.tool_result_content, log.tool_result_error === true)
  }

  return null
}

function baseMessage(log: TranscriptLog): Pick<ChatMessageItem, "type" | "id" | "text" | "bookmarkable" | "created_at"> {
  return { type: "message", id: log.id, text: log.chunk, bookmarkable: false, created_at: log.created_at || undefined }
}

function assistantMessage(log: TranscriptLog): ChatMessageItem {
  return { ...baseMessage(log), role: "assistant" }
}

function systemMessage(log: TranscriptLog): ChatMessageItem {
  return { ...baseMessage(log), role: "system" }
}

function toolUseMessage(log: TranscriptLog, toolName: string, input: Record<string, unknown>, toolUseId: string): ChatMessageItem {
  return {
    ...baseMessage(log),
    role: "tool_use",
    tool_name: toolName,
    content: { type: "tool_use", id: toolUseId, name: toolName, input }
  }
}

function toolResultMessage(log: TranscriptLog, toolUseId: string, content: unknown, isError: boolean): ChatMessageItem {
  return {
    ...baseMessage(log),
    role: "tool_result",
    content: { type: "tool_result", tool_use_id: toolUseId, content, is_error: isError }
  }
}

function recordInput(input: unknown): Record<string, unknown> {
  return input && typeof input === "object" && !Array.isArray(input) ? (input as Record<string, unknown>) : {}
}

function lastLegacyCallIndex(calls: Array<{ command: string }>, command: string) {
  for (let index = calls.length - 1; index >= 0; index -= 1) {
    if (calls[index]?.command === command) return index
  }
  return -1
}
