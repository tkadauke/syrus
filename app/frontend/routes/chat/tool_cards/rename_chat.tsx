import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, EmptyState, EntityReference } from "../toolCardUi"
import { ErrorCard, MalformedCard, StatusCard, successOrError } from "../chatHelperToolCard"

type RenameChatResult = { sessionId: string; title: string; previousTitle: string | null; requestedName: string | null }

function parseRenameChat(context: ToolCardContext) {
  if (!context.resultError && context.parsedResult == null && !context.resultBody) return { kind: "pending" } as const

  return successOrError<RenameChatResult>(context, "Chat rename failed.", (parsed) => {
    const sessionId = displayValue(parsed.session_id)
    const title = displayValue(parsed.title)
    if (!sessionId || !title) return null
    return {
      sessionId,
      title,
      previousTitle: displayValue(parsed.previous_title),
      requestedName: displayValue(context.input?.name)
    }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseRenameChat(context)
  if (parsed.kind === "pending") return "Renaming chat"
  if (parsed.kind === "error") return "Chat rename failed"
  if (parsed.kind === "malformed") return "Chat rename returned an unexpected response"
  if (parsed.data.previousTitle) return `Renamed "${parsed.data.previousTitle}" -> "${parsed.data.title}"`
  return `Renamed chat to "${parsed.data.title}"`
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseRenameChat(context)
  if (parsed.kind === "pending") {
    return (
      <StatusCard title="Chat rename" status="pending">
        <TitleField label="Requested title" value={displayValue(context.input?.name)} />
      </StatusCard>
    )
  }
  if (parsed.kind === "error") return <ErrorCard title="Chat rename" message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title="Chat rename" />

  const requestedDiffers = parsed.data.requestedName && parsed.data.requestedName !== parsed.data.title

  return (
    <StatusCard title="Chat rename" status="renamed">
      <dl className="grid gap-1 sm:grid-cols-2">
        <div className="min-w-0">
          <dt className="text-xs font-medium text-text-subtle">Chat</dt>
          <dd>
            <EntityReference id={parsed.data.sessionId} kind="chat" />
          </dd>
        </div>
        {parsed.data.previousTitle ? <TitleField label="Old title" value={parsed.data.previousTitle} /> : null}
        {requestedDiffers ? <TitleField label="Requested title" value={parsed.data.requestedName} /> : null}
        <TitleField label="Stored title" value={parsed.data.title} />
      </dl>
    </StatusCard>
  )
}

function TitleField({ label, value }: { label: string; value: string | null }) {
  return (
    <div className="min-w-0">
      <dt className="text-xs font-medium text-text-subtle">{label}</dt>
      <dd className="whitespace-pre-wrap break-words font-mono text-xs text-text-primary">{value ?? <EmptyState>Not provided.</EmptyState>}</dd>
    </div>
  )
}

const renameChatToolCard: ToolCardRenderer = {
  toolName: "rename_chat",
  renderWhilePending: true,
  collapsedSummary,
  renderExpanded
}

export default renameChatToolCard

export const examples: ToolCardExample[] = [
  {
    id: "renamed_with_shortened_title",
    label: "Renamed with shortened stored title",
    input: { name: `${"Long requested title ".repeat(7)}ending` },
    parsedResult: {
      session_id: 42,
      previous_title: "Old title",
      title: `${"Long requested title ".repeat(5)}stored ending`
    }
  },
  {
    id: "rename_pending",
    label: "Rename pending",
    input: { name: "Release planning" }
  },
  {
    id: "name_required",
    label: "Error: name is required",
    input: { name: "" },
    resultError: true,
    resultBody: "name is required"
  },
  {
    id: "name_too_long",
    label: "Error: name is too long",
    input: { name: "x".repeat(121) },
    resultError: true,
    resultBody: "name must be 120 characters or fewer"
  }
]
