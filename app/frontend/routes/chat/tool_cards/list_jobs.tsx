import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "../../../pluginToolCards"
import { JobRowList, parseJobRow, type JobRowData } from "./shared/jobRows"

// Core-owned tool card (EPIC-291 / JOB-4220) for `list_jobs`: a dense,
// scannable list of Jobs (id, state, title, repository, PR, branch,
// priority) instead of raw JSON.
function jobRows(context: ToolCardContext): JobRowData[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.jobs)) return null

  const jobs = parsed.jobs.flatMap((entry) => {
    const row = parseJobRow(entry)
    return row ? [row] : []
  })
  return jobs.length > 0 ? jobs : null
}

function renderExpanded(context: ToolCardContext) {
  const jobs = jobRows(context)
  if (!jobs) return null

  return <JobRowList jobs={jobs} />
}

const listJobsToolCard: ToolCardRenderer = {
  toolName: "list_jobs",
  renderExpanded
}

export default listJobsToolCard
