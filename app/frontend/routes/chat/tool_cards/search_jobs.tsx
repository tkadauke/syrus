import { type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { useT } from "../../../hooks/useT"
import { EmptyState } from "../toolCardUi"
import { JobsTable, jobResult, parseJobRow, resultErrorMessage, type JobRow } from "../jobsTableCard"

// Core-owned tool card for search_jobs (the Tier 1 tool-card work). Renders
// results as a dense table optimized for scanning, same shape as list_jobs.
function jobResultRows(context: ToolCardContext): { rows: JobRow[]; total: number } | null {
  const parsed = jobResult(context, "results")
  if (!parsed) return null

  const rows = parsed.items.flatMap((job) => {
    const row = parseJobRow(job)
    return row ? [row] : []
  })
  return { rows, total: parsed.total ?? rows.length }
}

function collapsedSummary(context: ToolCardContext) {
  const result = jobResultRows(context)
  if (!result) return null

  const count = result.total
  return `${count} matching Job${count === 1 ? "" : "s"}`
}

function SearchContext({ context, shown, total }: { context: ToolCardContext; shown?: number; total?: number }) {
  const { t } = useT("chat")
  const query = typeof context.input?.query === "string" && context.input.query.trim() ? context.input.query.trim() : null
  const state = typeof context.input?.state === "string" && context.input.state.trim() ? context.input.state.trim() : null

  return (
    <div className="mb-1 break-words text-xs text-text-muted [overflow-wrap:anywhere]">
      {shown == null || total == null ? null : `${t("search_jobs_showing", { shown, total })} · `}
      {t("search_jobs_query", { query: query ?? t("search_jobs_all") })} · {t("search_jobs_state", { state: state ?? t("search_jobs_any") })} ·{" "}
      {t("search_jobs_order")}
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const error = resultErrorMessage(context)
  if (error) {
    return (
      <div>
        <SearchContext context={context} />
        <EmptyState>{error}</EmptyState>
      </div>
    )
  }
  const result = jobResultRows(context)
  if (!result) return null
  return (
    <div>
      <SearchContext context={context} shown={result.rows.length} total={result.total} />
      <JobsTable emptyMessage="No Jobs matched the search." rows={result.rows} />
    </div>
  )
}

const searchJobsToolCard: ToolCardRenderer = {
  toolName: "search_jobs",
  collapsedSummary,
  renderExpanded
}

export default searchJobsToolCard

export const examples = [
  {
    id: "matching_jobs",
    label: "Matching Jobs",
    input: { query: "tool cards", state: "running", limit: 2 },
    parsedResult: {
      total: 37,
      results: [
        {
          id: 4048,
          repository_slug: "acme/widgets",
          kind: "issue",
          issue_title: "Improve search tool cards",
          state: "running",
          pr_number: 12,
          priority: "high",
          updated_at: "2026-10-19T11:30:00Z"
        },
        {
          id: 4049,
          repository_slug: "acme/widgets",
          kind: "direct",
          issue_title: "Add readable tool card titles",
          state: "running",
          priority: "medium",
          updated_at: "2026-10-18T10:00:00Z"
        }
      ]
    }
  },
  { id: "no_matches", label: "No matches", input: { query: "missing" }, parsedResult: { total: 0, results: [] } },
  { id: "tool_error", label: "Tool error", input: { query: "broken", state: "failed" }, resultBody: "Error: search unavailable", resultError: true }
]
