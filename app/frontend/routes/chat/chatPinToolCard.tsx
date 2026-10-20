import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, EntityReference, numberValue, Row, SectionLabel } from "./toolCardUi"
import { ErrorCard, MalformedCard, StatusCard, successOrError } from "./chatHelperToolCard"

type ChatPinResult = {
  sessionId: string
  title: string
  pinned: boolean
  message: string
  position: number | null
}

function parseChatPin(context: ToolCardContext, fallbackError: string) {
  if (!context.resultError && context.resultSettled === false) return { kind: "pending" as const }

  return successOrError<ChatPinResult>(context, fallbackError, (parsed) => {
    const sessionId = displayValue(parsed.session_id)
    const title = displayValue(parsed.title)
    const message = displayValue(parsed.message)
    if (!sessionId || !title || typeof parsed.pinned !== "boolean" || !message) return null
    const position = numberValue(parsed.position ?? parsed.pinned_position)
    return { sessionId, title, pinned: parsed.pinned, message, position }
  })
}

function requestedChatId(context: ToolCardContext) {
  return displayValue(context.input?.chat_session_id)
}

function ChatReference({ id, label = "Chat" }: { id: string; label?: string }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <EntityReference id={id} kind="chat" />
    </div>
  )
}

function errorMessage(context: ToolCardContext, fallback: string) {
  if (context.parsedResult && typeof context.parsedResult === "object" && !Array.isArray(context.parsedResult)) {
    const result = context.parsedResult as Record<string, unknown>
    return displayValue(result.message) ?? displayValue(result.error) ?? displayValue(result.code) ?? fallback
  }
  return displayValue(context.resultBody) ?? fallback
}

export function chatPinToolCard(toolName: "pin_chat" | "unpin_chat"): ToolCardRenderer {
  const expectedPinned = toolName === "pin_chat"
  const title = expectedPinned ? "Chat pin" : "Chat unpin"
  const errorSummary = expectedPinned ? "Chat pin failed" : "Chat unpin failed"
  const malformedSummary = expectedPinned ? "Chat pin returned an unexpected response" : "Chat unpin returned an unexpected response"

  return {
    toolName,
    collapsedSummary(context) {
      const parsed = parseChatPin(context, `${errorSummary}.`)
      if (parsed.kind === "error") return errorSummary
      if (parsed.kind === "malformed") return malformedSummary
      if (parsed.kind === "pending") return expectedPinned ? "Pinning chat..." : "Unpinning chat..."
      return parsed.data.message
    },
    renderExpanded(context) {
      const parsed = parseChatPin(context, `${errorSummary}.`)
      if (parsed.kind === "error") return <ErrorCard title={title} message={errorMessage(context, parsed.message)} />
      if (parsed.kind === "malformed") return <MalformedCard title={title} />
      if (parsed.kind === "pending") {
        const targetId = requestedChatId(context)
        return (
          <StatusCard title={title} status="pending">
            {targetId ? <ChatReference id={targetId} label="Requested target" /> : <Row label="Requested target" value="Current chat" />}
          </StatusCard>
        )
      }

      return (
        <StatusCard title={title} status={parsed.data.pinned ? "pinned" : "unpinned"}>
          <dl className="grid gap-1 sm:grid-cols-2">
            {requestedChatId(context) ? <ChatReference id={requestedChatId(context)!} label="Requested target" /> : null}
            <ChatReference id={parsed.data.sessionId} />
            <div className="min-w-0">
              <SectionLabel>Title</SectionLabel>
              <EntityReference className="whitespace-normal break-words" id={parsed.data.sessionId} kind="chat" label={parsed.data.title} wrap="break" />
            </div>
            <Row label="State" value={parsed.data.pinned ? "Pinned" : "Unpinned"} />
            {parsed.data.position != null ? <Row label="Position" value={String(parsed.data.position)} /> : null}
            <Row label="Result" value={parsed.data.message} />
          </dl>
        </StatusCard>
      )
    }
  }
}

export function chatPinToolCardExamples(toolName: "pin_chat" | "unpin_chat"): ToolCardExample[] {
  const pinned = toolName === "pin_chat"
  return [
    {
      id: "explicit_target",
      label: pinned ? "Explicit chat pinned" : "Explicit chat unpinned",
      input: { chat_session_id: 42 },
      parsedResult: {
        session_id: 42,
        title: "A long release-planning title that wraps on narrow screens",
        pinned,
        message: pinned ? "Chat pinned." : "Chat unpinned."
      },
      sourceType: "generic"
    },
    {
      id: "pending",
      label: pinned ? "Pin pending" : "Unpin pending",
      input: { chat_session_id: 42 },
      parsedResult: null,
      resultSettled: false,
      sourceType: "generic"
    },
    {
      id: "empty_result",
      label: pinned ? "Pin completed with an empty result" : "Unpin completed with an empty result",
      input: { chat_session_id: 42 },
      parsedResult: null,
      sourceType: "generic"
    },
    {
      id: "not_authorized",
      label: "Not authorized",
      parsedResult: { error: "not_authorized" },
      resultError: true,
      sourceType: "generic"
    }
  ]
}
