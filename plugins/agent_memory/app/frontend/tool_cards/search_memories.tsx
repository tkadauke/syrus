import i18n from "i18next"
import { type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, CardShell, EmptyState, numberValue, Row } from "@app/routes/chat/toolCardUi"
import { ErrorCard, memoryRows, MemoryListBody, memoryListSummary, parseMemoryToolError } from "../memoryToolCard"

// Plugin-owned tool card for search_memories (the tool-card work). Shares its list
// rendering with list_memories -- both tools return the same
// `{ memories: [memory_payload, ...] }` shape.
function collapsedSummary(context: ToolCardContext) {
  const query = displayValue(context.input?.query)
  const error = parseMemoryToolError(context)
  if (error) return t("tool_search_failed_summary", { query: query ?? t("tool_search_unknown_query") })
  if (isPending(context)) return t("tool_search_pending_summary", { query: query ?? t("tool_search_unknown_query") })
  return memoryListSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  const query = displayValue(context.input?.query)
  const scope = displayValue(context.input?.scope)
  const kind = displayValue(context.input?.kind)
  const limit = numberValue(context.input?.limit)
  const error = parseMemoryToolError(context)
  const inputs = (
    <dl className="grid min-w-0 gap-2 sm:grid-cols-2 lg:grid-cols-4">
      {query ? <Row label={t("tool_search_query")} value={query} /> : null}
      {scope ? <Row label={t("tool_input_scope")} value={scope} /> : null}
      {kind ? <Row label={t("tool_input_kind")} value={kind} /> : null}
      {limit != null ? <Row label={t("tool_search_limit")} value={String(limit)} /> : null}
    </dl>
  )

  if (error)
    return (
      <CardShell>
        {inputs}
        <ErrorCard error={error} title={t("tool_search_error_title")} />
      </CardShell>
    )
  if (isPending(context))
    return (
      <CardShell>
        {inputs}
        <EmptyState>{t("tool_search_pending", { query: query ?? t("tool_search_unknown_query") })}</EmptyState>
      </CardShell>
    )

  const rows = memoryRows(context)
  if (!rows) return null

  return (
    <CardShell>
      {inputs}
      <MemoryListBody
        emptyMessage={t("tool_search_empty", { query: query ?? t("tool_search_unknown_query") })}
        highlightTerms={query ? [query] : undefined}
        rows={rows}
      />
    </CardShell>
  )
}

function isPending(context: ToolCardContext) {
  return !context.resultError && context.parsedResult == null && !context.resultBody.trim()
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`agent_memory:${key}`, options)
}

const searchMemoriesToolCard: ToolCardRenderer = {
  toolName: "search_memories",
  collapsedSummary,
  renderExpanded
}

export default searchMemoriesToolCard

export const examples: ToolCardExample[] = [
  {
    id: "matching_memories",
    label: "Matching memories",
    input: { query: "policy objects", scope: "repository", kind: "decision", limit: 10 },
    parsedResult: {
      memories: [
        {
          id: "8",
          kind: "decision",
          scope: "repository",
          scope_id: "42",
          content: "Use **policy objects** for enum branching. See JOB-42 and https://example.com/guide.",
          published: true,
          author: "agent",
          confidence: 0.9,
          expires_at: "2027-01-01T00:00:00Z",
          last_verified_at: "2026-10-18T12:00:00Z",
          created_at: "2026-10-17T12:00:00Z",
          updated_at: "2026-10-18T12:00:00Z",
          deleted_at: null
        }
      ]
    }
  },
  { id: "no_matches", label: "No matching memories", input: { query: "missing phrase", limit: 5 }, parsedResult: { memories: [] } },
  { id: "pending", label: "Pending search", input: { query: "policy objects" } },
  { id: "error", label: "Search error", input: { query: "policy objects" }, resultBody: "Error: memory search unavailable", resultError: true }
]
