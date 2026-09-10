import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, Row } from "../toolCardUi"
import { ErrorCard, MalformedCard, StatusCard, successOrError } from "../chatHelperToolCard"

type RenameChatResult = { sessionId: string; title: string; previousTitle: string | null }

function parseRenameChat(context: ToolCardContext) {
  return successOrError<RenameChatResult>(context, "Chat rename failed.", (parsed) => {
    const sessionId = displayValue(parsed.session_id)
    const title = displayValue(parsed.title)
    if (!sessionId || !title) return null
    return { sessionId, title, previousTitle: displayValue(parsed.previous_title) }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseRenameChat(context)
  if (parsed.kind === "error") return "Chat rename failed"
  if (parsed.kind === "malformed") return "Chat rename returned an unexpected response"
  if (parsed.data.previousTitle) return `Renamed "${parsed.data.previousTitle}" -> "${parsed.data.title}"`
  return `Renamed chat to "${parsed.data.title}"`
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseRenameChat(context)
  if (parsed.kind === "error") return <ErrorCard title="Chat rename" message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title="Chat rename" />

  return (
    <StatusCard title="Chat rename" status="renamed">
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Chat" value={`#${parsed.data.sessionId}`} />
        {parsed.data.previousTitle ? <Row label="Old title" value={parsed.data.previousTitle} /> : null}
        <Row label="New title" value={parsed.data.title} />
      </dl>
    </StatusCard>
  )
}

const renameChatToolCard: ToolCardRenderer = {
  toolName: "rename_chat",
  collapsedSummary,
  renderExpanded
}

export default renameChatToolCard
