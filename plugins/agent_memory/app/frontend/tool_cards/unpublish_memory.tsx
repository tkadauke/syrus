import i18n from "i18next"
import { type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { ErrorCard, MemoryDetailBody, MemoryRef, parseMemoryDetail, parseMemoryToolError } from "../memoryToolCard"

// Plugin-owned tool card for unpublish_memory (the tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const error = parseMemoryToolError(context)
  if (error) return t("tool_unpublish_failed", { message: error.message })
  const memory = parseMemoryDetail(context)
  if (!memory) return isPending(context) ? t("tool_unpublish_pending") : null

  return t("tool_unpublish_summary", { id: memory.id })
}

function renderExpanded(context: ToolCardContext) {
  const error = parseMemoryToolError(context)
  if (error) return <ErrorCard error={error} title={t("tool_unpublish_error_title")} />
  const memory = parseMemoryDetail(context)
  if (!memory) {
    if (!isPending(context)) return null
    return <EmptyState>{t("tool_unpublish_pending")}</EmptyState>
  }

  const requestedId = displayValue(context.input?.memory_id)

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={t("tool_status_published")} tone="success" />
        <span aria-hidden="true" className="text-text-muted">
          →
        </span>
        <StatePill state={t("tool_status_private")} tone="neutral" />
      </div>
      {requestedId ? (
        <div className="min-w-0">
          <SectionLabel>{t("tool_input_memory_id")}</SectionLabel>
          <MemoryRef id={requestedId} />
        </div>
      ) : null}
      <MemoryDetailBody memory={memory} shell={false} />
    </CardShell>
  )
}

function isPending(context: ToolCardContext) {
  return !context.resultError && context.parsedResult == null && !context.resultBody.trim()
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`agent_memory:${key}`, options)
}

const unpublishMemoryToolCard: ToolCardRenderer = {
  toolName: "unpublish_memory",
  collapsedSummary,
  renderExpanded
}

export default unpublishMemoryToolCard

export const examples: ToolCardExample[] = [
  {
    id: "repository_memory_unpublished",
    label: "Repository memory unpublished",
    input: { memory_id: "21" },
    parsedResult: {
      memory: {
        id: "21",
        kind: "decision",
        scope: "repository",
        scope_id: "42",
        content: "Keep the **rollout private**. See https://example.com/runbook.",
        published: false,
        author: "Operator",
        confidence: 0.9,
        expires_at: "2027-01-01T00:00:00Z",
        last_verified_at: "2026-10-18T12:00:00Z",
        created_at: "2026-10-17T12:00:00Z",
        updated_at: "2026-10-18T12:00:00Z"
      }
    }
  },
  {
    id: "not_owned",
    label: "Memory unavailable error",
    input: { memory_id: "999" },
    resultBody: "Error: memory not found or not owned: 999",
    resultError: true
  },
  { id: "pending", label: "Pending unpublish", input: { memory_id: "21" } }
]
