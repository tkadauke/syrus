import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { ErrorCard, MemoryDetailBody, MemoryRef, parseMemoryDetail, parseMemoryToolError, ScopeRef } from "../memoryToolCard"

function previousPublished(context: ToolCardContext): boolean | null {
  if (!isPlainObject(context.parsedResult) || typeof context.parsedResult.previous_published !== "boolean") return null
  return context.parsedResult.previous_published
}

function collapsedSummary(context: ToolCardContext) {
  const error = parseMemoryToolError(context)
  if (error) return t("tool_publish_failed", { message: error.message })
  const memory = parseMemoryDetail(context)
  if (!memory) return isPending(context) ? t("tool_publish_pending") : null
  return t(previousPublished(context) ? "tool_publish_already_summary" : "tool_publish_summary", { id: memory.id })
}

function renderExpanded(context: ToolCardContext) {
  const error = parseMemoryToolError(context)
  const requestedId = displayValue(context.input?.memory_id)
  if (error) {
    return (
      <CardShell>
        <RequestedMemory id={requestedId} />
        <ErrorCard error={error} title={t("tool_publish_error_title")} />
      </CardShell>
    )
  }

  const memory = parseMemoryDetail(context)
  if (!memory) {
    if (!isPending(context)) return null
    return (
      <CardShell>
        <RequestedMemory id={requestedId} />
        <EmptyState>{t("tool_publish_pending")}</EmptyState>
      </CardShell>
    )
  }

  const wasPublished = previousPublished(context)
  return (
    <CardShell>
      {wasPublished === false ? (
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <StatePill state={t("tool_status_private")} tone="neutral" />
          <span aria-label={t("tool_state_change")} className="text-xs text-text-muted">
            →
          </span>
          <StatePill state={t("tool_status_published")} tone="success" />
        </div>
      ) : wasPublished === true ? (
        <StatePill state={t("tool_status_already_published")} tone="success" />
      ) : null}
      <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
        <RequestedMemory id={requestedId} />
        <div className="min-w-0">
          <SectionLabel>{t("tool_visibility")}</SectionLabel>
          <ScopeRef memory={memory} />
        </div>
      </dl>
      <MemoryDetailBody memory={memory} shell={false} />
    </CardShell>
  )
}

function RequestedMemory({ id }: { id: string | null }) {
  if (!id) return null
  return (
    <div className="min-w-0">
      <SectionLabel>{t("tool_requested_memory")}</SectionLabel>
      <MemoryRef id={id} />
    </div>
  )
}

function isPending(context: ToolCardContext) {
  return !context.resultError && context.parsedResult == null && !context.resultBody.trim()
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`agent_memory:${key}`, options)
}

const publishMemoryToolCard: ToolCardRenderer = { toolName: "publish_memory", collapsedSummary, renderExpanded }
export default publishMemoryToolCard

export const examples: ToolCardExample[] = [
  {
    id: "repository_memory_published",
    label: "Repository memory published",
    input: { memory_id: "20" },
    parsedResult: {
      previous_published: false,
      memory: {
        id: "20",
        kind: "decision",
        scope: "repository",
        scope_id: "3",
        content: "Ship **weekly**. See JOB-42 and https://example.com/release.",
        published: true,
        author: "operator@example.com",
        confidence: 0.9,
        expires_at: "2027-01-01T00:00:00Z",
        last_verified_at: "2026-10-18T12:00:00Z",
        created_at: "2026-10-17T12:00:00Z",
        updated_at: "2026-10-18T12:00:00Z"
      }
    }
  },
  {
    id: "already_published",
    label: "Memory was already published",
    input: { memory_id: "20" },
    parsedResult: {
      previous_published: true,
      memory: { id: "20", kind: "decision", scope: "repository", scope_id: "3", content: "Still current.", published: true }
    }
  },
  {
    id: "global_memory_error",
    label: "Global memory cannot be published",
    input: { memory_id: "21" },
    resultBody: "Error: global memories cannot be published",
    resultError: true
  },
  { id: "pending", label: "Pending publish", input: { memory_id: "20" } },
  {
    id: "blank_content",
    label: "Published memory with blank content",
    input: { memory_id: "22" },
    parsedResult: { previous_published: false, memory: { id: "22", kind: "feedback", scope: "repository", scope_id: "3", content: "", published: true } }
  }
]
