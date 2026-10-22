import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { displayValue, EmptyState, EntityReference, Row } from "../toolCardUi"

function requestedJobIds(context: ToolCardContext) {
  const ids = Array.isArray(context.input?.job_ids) ? context.input.job_ids : context.input?.job_id == null ? [] : [context.input.job_id]
  return ids.flatMap((id) => {
    const value = displayValue(id)
    return value ? [value] : []
  })
}

function RequestedJobs({ context }: { context: ToolCardContext }) {
  const jobIds = requestedJobIds(context)
  return (
    <Row
      label={jobIds.length === 1 ? "Job" : "Jobs"}
      value={
        jobIds.length ? (
          <div className="flex min-w-0 flex-wrap gap-x-2 gap-y-1">
            {jobIds.map((jobId) => (
              <EntityReference id={jobId} key={jobId} kind="job" />
            ))}
          </div>
        ) : (
          <EmptyState>Not provided</EmptyState>
        )
      }
    />
  )
}

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? <PendingActionResultCard detailTitle="Landing recheck outcome" details={<RequestedJobs context={context} />} omitJob result={result} /> : null
}

const forceLandingRecheckToolCard: ToolCardRenderer = {
  toolName: "force_landing_recheck",
  collapsedSummary,
  renderExpanded
}

export default forceLandingRecheckToolCard
