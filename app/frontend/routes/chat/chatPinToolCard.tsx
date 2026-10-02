import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, Row } from "./toolCardUi"
import { ErrorCard, MalformedCard, StatusCard, successOrError } from "./chatHelperToolCard"

type ChatPinResult = {
  sessionId: string
  title: string
  pinned: boolean
  message: string
}

function parseChatPin(context: ToolCardContext, fallbackError: string) {
  return successOrError<ChatPinResult>(context, fallbackError, (parsed) => {
    const sessionId = displayValue(parsed.session_id)
    const title = displayValue(parsed.title)
    const message = displayValue(parsed.message)
    if (!sessionId || !title || typeof parsed.pinned !== "boolean" || !message) return null
    return { sessionId, title, pinned: parsed.pinned, message }
  })
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
      return parsed.data.message
    },
    renderExpanded(context) {
      const parsed = parseChatPin(context, `${errorSummary}.`)
      if (parsed.kind === "error") return <ErrorCard title={title} message={parsed.message} />
      if (parsed.kind === "malformed") return <MalformedCard title={title} />

      return (
        <StatusCard title={title} status={parsed.data.pinned ? "pinned" : "unpinned"}>
          <dl className="grid gap-1 sm:grid-cols-2">
            <Row label="Chat" value={`#${parsed.data.sessionId}`} />
            <Row label="Title" value={parsed.data.title} />
            <Row label="State" value={parsed.data.pinned ? "Pinned" : "Unpinned"} />
          </dl>
        </StatusCard>
      )
    }
  }
}
