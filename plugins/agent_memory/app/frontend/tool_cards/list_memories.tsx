import i18n from "i18next"
import { type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, Row } from "@app/routes/chat/toolCardUi"
import { ErrorCard, memoryRows, MemoryListBody, memoryListSummary, parseMemoryToolError } from "../memoryToolCard"

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`agent_memory:${key}`, options)
}

function isPending(context: ToolCardContext) {
  return context.parsedResult == null && !context.resultError && context.resultBody.trim() === ""
}

// Plugin-owned tool card for list_memories (the tool-card work). Lives entirely
// inside the agent_memory plugin -- core discovers it by directory
// convention (see app/frontend/pluginToolCards.tsx) and never imports it by
// name, so it can be added, changed, or removed without touching core.
function collapsedSummary(context: ToolCardContext) {
  const error = parseMemoryToolError(context)
  if (error) return t("tool_list_failed", { message: error.message })
  return memoryListSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  const error = parseMemoryToolError(context)
  if (error) return <ErrorCard error={error} title={t("tool_list_error_title")} />
  const rows = memoryRows(context)
  if (!rows) return isPending(context) ? <EmptyState>{t("tool_list_pending")}</EmptyState> : null

  const scope = displayValue(context.input?.scope)
  const kind = displayValue(context.input?.kind)
  const limit = displayValue(context.input?.limit)

  return (
    <CardShell>
      {scope || kind || limit ? (
        <dl className="grid min-w-0 gap-1 sm:grid-cols-3">
          {scope ? <Row label={t("tool_input_scope")} value={scope} /> : null}
          {kind ? <Row label={t("tool_input_kind")} value={kind} /> : null}
          {limit ? <Row label={t("tool_input_limit")} value={limit} /> : null}
        </dl>
      ) : null}
      <MemoryListBody emptyMessage={t("tool_list_empty")} rows={rows} />
    </CardShell>
  )
}

const listMemoriesToolCard: ToolCardRenderer = {
  toolName: "list_memories",
  collapsedSummary,
  renderExpanded
}

export default listMemoriesToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples: ToolCardExample[] = [
  {
    id: "two_repository_memories",
    label: "Two repository-scoped memories",
    input: { scope: "repository", kind: "feedback", limit: 20 },
    parsedResult: {
      memories: [
        {
          id: "133",
          kind: "feedback",
          scope: "repository",
          scope_id: "42",
          content: "Every new MCP tool registered on the chat surface needs an explicit rendering decision.",
          published: true,
          author: "agent",
          confidence: 0.9,
          created_at: "2026-09-10T14:22:00Z",
          updated_at: "2026-09-10T14:22:00Z",
          deleted_at: null
        },
        {
          id: "126",
          kind: "project_fact",
          scope: "repository",
          scope_id: "42",
          content: "When adding or changing Syrus ApplicationJob classes, explicitly set queue_as to a consumed queue.",
          published: false,
          author: "agent",
          confidence: null,
          created_at: "2026-08-30T09:10:00Z",
          updated_at: "2026-08-30T09:10:00Z",
          deleted_at: null
        }
      ]
    }
  },
  {
    id: "no_matching_memories",
    label: "No matching memories",
    description: "Empty result set -- the card renders MemoryListBody's own empty-state message.",
    input: { kind: "decision" },
    parsedResult: { memories: [] }
  },
  {
    id: "pending",
    label: "Pending list",
    input: { scope: "global", limit: 10 },
    resultBody: ""
  },
  {
    id: "list_error",
    label: "List error",
    input: { kind: "feedback" },
    resultBody: "Error: Memory provider unavailable.",
    resultError: true
  }
]
