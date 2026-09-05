import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "../../../pluginToolCards"
import { JobRowList, parseJobRow, type JobRowData } from "./shared/jobRows"

// Core-owned tool card (EPIC-291 / JOB-4220) for `search_jobs`: same dense
// list as list_jobs, reading the `results` array `search_jobs` returns
// instead of `jobs` (job_search_payload doesn't carry branch_name or
// agent_provider, so those columns simply don't render for this tool).
function jobRows(context: ToolCardContext): JobRowData[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.results)) return null

  const jobs = parsed.results.flatMap((entry) => {
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

const searchJobsToolCard: ToolCardRenderer = {
  toolName: "search_jobs",
  renderExpanded
}

export default searchJobsToolCard
