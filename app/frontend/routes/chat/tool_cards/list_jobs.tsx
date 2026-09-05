import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { JobsTable, parseJobRow, type JobRow } from "../jobsTableCard"

// Core-owned tool card for list_jobs (EPIC-291 / JOB-4220). Renders results
// as a dense table optimized for scanning.
function jobRows(context: ToolCardContext): JobRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.jobs)) return null

  return parsed.jobs.flatMap((job) => {
    const row = parseJobRow(job)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = jobRows(context)
  if (!rows) return null
  return `${rows.length} Job${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const rows = jobRows(context)
  if (!rows) return null
  return <JobsTable emptyMessage="No Jobs found." rows={rows} />
}

const listJobsToolCard: ToolCardRenderer = {
  toolName: "list_jobs",
  collapsedSummary,
  renderExpanded
}

export default listJobsToolCard
