import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { ErrorCard, MalformedCard, successOrError } from "../chatHelperToolCard"
import { parsePinnedContextResult, pinnedContextIdentifiers, PinnedContextCard } from "../pinnedContextToolCard"
import { CardShell, StatePill } from "../toolCardUi"

function parseRemoval(context: ToolCardContext) {
  return successOrError(context, "Pinned context removal failed.", () => parsePinnedContextResult(context))
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseRemoval(context)
  if (parsed.kind === "error") return "Pinned context removal failed"
  if (parsed.kind === "malformed") return context.resultBody === "" ? "Removing pinned context" : "Pinned context removal returned an unexpected response"
  return parsed.data.message || "Pinned context removed"
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseRemoval(context)
  if (parsed.kind === "error") return <ErrorCard title="Pinned context" message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title="Pinned context" />

  const identifiers =
    typeof context.parsedResult === "object" && context.parsedResult ? pinnedContextIdentifiers(context.parsedResult as Record<string, unknown>) : {}
  return <PinnedContextCard {...identifiers} result={parsed.data} />
}

function renderPending() {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="pending" tone="info" />
        <span className="font-semibold text-text-primary">Removing pinned context</span>
      </div>
    </CardShell>
  )
}

const removePinnedContextToolCard: ToolCardRenderer = {
  toolName: "remove_pinned_context",
  collapsedSummary,
  renderExpanded,
  renderPending
}

export default removePinnedContextToolCard

export const examples: ToolCardExample[] = [
  {
    id: "removed_markdown",
    label: "Removed markdown context",
    parsedResult: {
      chat_id: 7,
      pinned_context: null,
      removed_pinned_context: "Remember **JOB-42** and https://example.test/runbook",
      message: "Pinned context removed."
    },
    sourceType: "generic"
  },
  {
    id: "nothing_pinned",
    label: "Nothing pinned error",
    resultBody: "No pinned context exists for this chat.",
    resultError: true,
    sourceType: "codex"
  }
]
