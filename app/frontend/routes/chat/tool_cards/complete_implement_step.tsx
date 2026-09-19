import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { JobRefLink } from "../adminToolCard"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { Badge, displayValue } from "../toolCardUi"

// Core-owned tool card for complete_implement_step. Reuses the shared
// pending-action parsing/rendering and adds the target Job and pushed
// branch read back from the tool call's own input arguments -- the result
// payload itself only carries the pending-action confirmation shape.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  if (!result) return null

  const input = isPlainObject(context.input) ? context.input : {}
  const jobId = displayValue(input.job_id)
  const branch = displayValue(input.branch_name)

  return (
    <div className="space-y-1">
      {jobId || branch ? (
        <div className="flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-300">
          {jobId ? <JobRefLink jobId={jobId} /> : null}
          {branch ? <Badge>{branch}</Badge> : null}
        </div>
      ) : null}
      <PendingActionResultCard result={result} />
    </div>
  )
}

const completeImplementStepToolCard: ToolCardRenderer = {
  toolName: "complete_implement_step",
  collapsedSummary,
  renderExpanded
}

export default completeImplementStepToolCard
