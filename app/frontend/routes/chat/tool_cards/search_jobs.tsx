import { type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
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
  const query = typeof context.input?.query === "string" && context.input.query.trim() ? context.input.query.trim() : null
  const state = typeof context.input?.state === "string" && context.input.state.trim() ? context.input.state.trim() : null

  return (
    <div className="mb-1 text-xs text-text-muted">
      {shown == null || total == null ? null : `Showing ${shown} of ${total} · `}
      Query: {query ?? "all Jobs"} · State: {state ?? "any"} · Ordered by most recently updated
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
