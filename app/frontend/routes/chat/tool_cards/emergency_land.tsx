import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { JobRefLink } from "../adminToolCard"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { Badge, displayValue } from "../toolCardUi"

function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context.parsedResult)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context.parsedResult)
  if (!result) return null

  const input = isPlainObject(context.input) ? context.input : {}
  const jobId = displayValue(input.job_id)
  const branch = displayValue(input.branch_name)

  return (
    <div className="space-y-2">
      {jobId || branch ? (
        <div className="flex flex-wrap items-center gap-2 text-xs text-text-secondary">
          {jobId ? <JobRefLink jobId={jobId} /> : null}
          {branch ? <Badge>{branch}</Badge> : null}
        </div>
      ) : null}
      <PendingActionResultCard result={result} />
    </div>
  )
}

const emergencyLandToolCard: ToolCardRenderer = {
  toolName: "emergency_land",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: "Pending emergency land confirmation",
    input: { job_id: 4242, branch_name: "syrus/incident-fix" },
    parsedResult: {
      pending_confirmation_id: 7001,
      pending_action_id: 7001,
      state: "pending",
      message: "Emergency land requires operator confirmation."
    }
  }
]

export default emergencyLandToolCard
