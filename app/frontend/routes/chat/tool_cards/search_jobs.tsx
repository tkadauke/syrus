import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { EmptyState } from "../toolCardUi"
import { JobsTable, jobResult, parseJobRow, resultErrorMessage, type JobRow } from "../jobsTableCard"

// Core-owned tool card for search_jobs (the Tier 1 tool-card work). Renders
// results as a dense table optimized for scanning, same shape as list_jobs.
function jobRows(context: ToolCardContext): JobRow[] | null {
  const parsed = jobResult(context, "results")
  if (!parsed) return null

  return parsed.flatMap((job) => {
    const row = parseJobRow(job)
    return row ? [row] : []
  })
}

function total(context: ToolCardContext, rows: JobRow[]) {
  const parsed = context.parsedResult
  return isPlainObject(parsed) && typeof parsed.total === "number" && Number.isFinite(parsed.total) ? parsed.total : rows.length
}

function collapsedSummary(context: ToolCardContext) {
  const rows = jobRows(context)
  if (!rows) return null

  const count = total(context, rows)
  return `${count} matching Job${count === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const error = resultErrorMessage(context)
  if (error) return <EmptyState>{error}</EmptyState>
  const rows = jobRows(context)
  if (!rows) return null
  return <JobsTable emptyMessage="No Jobs matched the search." rows={rows} />
}

const searchJobsToolCard: ToolCardRenderer = {
  toolName: "search_jobs",
  collapsedSummary,
  renderExpanded
}

export default searchJobsToolCard
