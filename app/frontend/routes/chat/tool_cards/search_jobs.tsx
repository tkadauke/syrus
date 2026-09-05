import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { JobsTable, parseJobRow, type JobRow } from "../jobsTableCard"

// Core-owned tool card for search_jobs (EPIC-291 / JOB-4220). Renders
// results as a dense table optimized for scanning, same shape as list_jobs.
function jobRows(context: ToolCardContext): JobRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.results)) return null

  return parsed.results.flatMap((job) => {
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
