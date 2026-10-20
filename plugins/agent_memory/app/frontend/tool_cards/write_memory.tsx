import i18n from "i18next"
import { type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, EntityReference, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { ErrorCard, MemoryDetailBody, parseMemoryDetail, parseMemoryToolError } from "../memoryToolCard"

// Plugin-owned tool card for write_memory (the tool-card work). write_memory's
// response is `{ id, memory: memory_payload }` -- the same detail shape
// read_memory/publish_memory/unpublish_memory share.
function collapsedSummary(context: ToolCardContext) {
  const error = parseMemoryToolError(context)
  if (error) return t("tool_write_failed", { message: error.message })
  const memory = parseMemoryDetail(context)
  if (!memory) return isPending(context) ? t("tool_write_pending") : null

  return t("tool_write_summary", { id: memory.id, kind: memory.kind ?? t("tool_unknown_kind") })
}

function renderExpanded(context: ToolCardContext) {
  const error = parseMemoryToolError(context)
  if (error) return <ErrorCard error={error} />
  const memory = parseMemoryDetail(context)
  if (!memory) {
    if (!isPending(context)) return null
    return <EmptyState>{t("tool_write_pending")}</EmptyState>
  }

  const scope = displayValue(context.input?.scope)
  const scopeId = displayValue(context.input?.scope_id)
  const kind = displayValue(context.input?.kind)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={t("tool_status_written")} tone="success" />
      </div>
      {scope || scopeId || kind ? (
        <dl className="grid min-w-0 gap-1 sm:grid-cols-3">
          {scope ? <Row label={t("tool_input_scope")} value={scope} /> : null}
          {scopeId ? (
            <div className="min-w-0">
              <SectionLabel>{t("tool_input_scope_id")}</SectionLabel>
              <EntityReference id={scopeId} kind="repository" label={t("tool_scope_repository_id", { id: scopeId })} repositoryId={scopeId} wrap="break" />
            </div>
          ) : null}
          {kind ? <Row label={t("tool_input_kind")} value={kind} /> : null}
        </dl>
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

const writeMemoryToolCard: ToolCardRenderer = {
  toolName: "write_memory",
  collapsedSummary,
  renderExpanded
}

export default writeMemoryToolCard

export const examples: ToolCardExample[] = [
  {
    id: "repository_memory_written",
    label: "Repository memory written",
    input: { scope: "repository", scope_id: "42", kind: "feedback" },
    parsedResult: {
      id: "55",
      memory: {
        id: "55",
        kind: "feedback",
        scope: "repository",
        scope_id: "42",
        content: "Use **focused tests**. See https://example.com/guide.",
        published: false,
        expires_at: "2027-01-01T00:00:00Z",
        last_verified_at: "2026-10-18T12:00:00Z",
        created_at: "2026-10-18T12:00:00Z",
        updated_at: "2026-10-18T12:00:00Z"
      }
    }
  },
  {
    id: "duplicate_memory",
    label: "Duplicate memory error",
    input: { scope: "global", kind: "feedback" },
    resultBody: "Error: similar feedback memory already exists as memory #55; read_memory that id instead",
    resultError: true
  },
  { id: "pending", label: "Pending write", input: { scope: "global", kind: "decision" } }
]
