import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, SectionLabel } from "@app/routes/chat/toolCardUi"
import { ErrorCard, MemoryDetailBody, MemoryRef, parseMemoryDetail, parseMemoryToolError } from "../memoryToolCard"

// Plugin-owned tool card for read_memory (the tool-card work).
function collapsedSummary(context: ToolCardContext) {
  const error = parseMemoryToolError(context)
  if (error) return t("tool_read_failed", { id: inputId(context) ?? t("tool_unknown_memory_id") })
  const memory = parseMemoryDetail(context)
  if (!memory) return isPending(context) ? t("tool_read_pending", { id: inputId(context) ?? t("tool_unknown_memory_id") }) : null

  return t("tool_read_summary", { id: memory.id, kind: memory.kind ?? t("tool_unknown_kind") })
}

function renderExpanded(context: ToolCardContext) {
  const id = inputId(context)
  const error = parseMemoryToolError(context)
  if (error) {
    return (
      <CardShell>
        {id ? <RequestedMemory id={id} /> : null}
        <ErrorCard error={error} title={t("tool_read_error_title")} />
      </CardShell>
    )
  }

  const memory = parseMemoryDetail(context)
  if (!memory) {
    if (isPending(context)) {
      return (
        <CardShell>
          {id ? <RequestedMemory id={id} /> : null}
          <EmptyState>{t("tool_read_pending", { id: id ?? t("tool_unknown_memory_id") })}</EmptyState>
        </CardShell>
      )
    }
    if (isPlainObject(context.parsedResult) && Object.hasOwn(context.parsedResult, "memory")) {
      return <EmptyState>{t("tool_read_empty")}</EmptyState>
    }
    return null
  }

  return <MemoryDetailBody memory={memory} />
}

function RequestedMemory({ id }: { id: string }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{t("tool_requested_memory")}</SectionLabel>
      <MemoryRef id={id} />
    </div>
  )
}

function inputId(context: ToolCardContext) {
  return displayValue(context.input?.id)
}

function isPending(context: ToolCardContext) {
  return !context.resultError && context.parsedResult == null && !context.resultBody.trim()
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`agent_memory:${key}`, options)
}

const readMemoryToolCard: ToolCardRenderer = {
  toolName: "read_memory",
  collapsedSummary,
  renderExpanded
}

export default readMemoryToolCard

export const examples: ToolCardExample[] = [
  {
    id: "repository_memory",
    label: "Repository memory",
    input: { id: 55 },
    parsedResult: {
      memory: {
        id: 55,
        kind: "feedback",
        scope: "repository",
        scope_id: 42,
        content: "Use **focused tests**. See JOB-42 and https://example.com/runbook.",
        published: true,
        author: "agent",
        confidence: 0.9,
        expires_at: "2027-01-01T00:00:00Z",
        last_verified_at: "2026-10-18T11:00:00Z",
        created_at: "2026-10-18T10:00:00Z",
        updated_at: "2026-10-18T12:00:00Z"
      }
    }
  },
  {
    id: "deleted_memory",
    label: "Deleted memory",
    input: { id: 56 },
    parsedResult: {
      memory: {
        id: 56,
        kind: "project_fact",
        scope: "global",
        content: "Retained audit context.",
        published: false,
        deleted_at: "2026-10-19T12:00:00Z"
      }
    }
  },
  { id: "not_found", label: "Memory not found", input: { id: 404 }, resultBody: "Error: memory not found or not accessible: 404", resultError: true },
  { id: "pending", label: "Pending read", input: { id: 55 } }
]
