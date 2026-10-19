import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue } from "../toolCardUi"
import { ErrorCard, MalformedCard, successOrError } from "../chatHelperToolCard"
import { parsePinnedContextResult, PendingPinnedContextCard, pinnedContextIdentifiers, PinnedContextCard } from "../pinnedContextToolCard"

function parseUpdate(context: ToolCardContext) {
  return successOrError(context, "Pinned context update failed.", () => parsePinnedContextResult(context))
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseUpdate(context)
  if (parsed.kind === "error") return "Pinned context update failed"
  if (parsed.kind === "malformed") return context.resultBody === "" ? "Updating pinned context" : "Pinned context update returned an unexpected response"
  return parsed.data.message || "Pinned context updated"
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseUpdate(context)
  if (parsed.kind === "error") return <ErrorCard title="Pinned context" message={parsed.message} />
  if (parsed.kind === "malformed") {
    return <MalformedCard title="Pinned context" />
  }

  const identifiers =
    typeof context.parsedResult === "object" && context.parsedResult ? pinnedContextIdentifiers(context.parsedResult as Record<string, unknown>) : {}
  return <PinnedContextCard {...identifiers} inputContent={displayValue(context.input?.content)} result={parsed.data} />
}

function renderPending(context: ToolCardContext) {
  return <PendingPinnedContextCard content={displayValue(context.input?.content)} />
}

const updatePinnedContextToolCard: ToolCardRenderer = {
  toolName: "update_pinned_context",
  collapsedSummary,
  renderExpanded,
  renderPending
}

export default updatePinnedContextToolCard

export const examples: ToolCardExample[] = [
  {
    id: "updated_markdown",
    label: "Updated markdown context",
    input: { content: "Remember **JOB-42** and https://example.test/runbook" },
    parsedResult: { pinned_context: "Remember **JOB-42** and https://example.test/runbook", message: "Pinned context updated.", chat_id: 7 },
    sourceType: "generic"
  },
  {
    id: "validation_error",
    label: "Validation error",
    input: { content: " " },
    resultBody: "content is required",
    resultError: true,
    sourceType: "codex"
  }
]
