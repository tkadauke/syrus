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

function renderExpanded(context: ToolCardContext) {
  const error = resultErrorMessage(context)
  if (error) return <EmptyState>{error}</EmptyState>
  const result = jobResultRows(context)
  if (!result) return null
  return <JobsTable emptyMessage="No Jobs matched the search." rows={result.rows} />
}

const searchJobsToolCard: ToolCardRenderer = {
  toolName: "search_jobs",
  collapsedSummary,
  renderExpanded
}

export default searchJobsToolCard
