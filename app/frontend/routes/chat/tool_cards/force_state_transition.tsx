import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { JobRefLink } from "../adminToolCard"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { Badge, displayValue } from "../toolCardUi"

// Core-owned tool card for force_state_transition. Reuses the shared
// pending-action parsing/rendering (which already surfaces the admin audit
// reason) and adds the target Job and requested AASM event read back from
// the tool call's own input arguments -- the result payload itself doesn't
// carry them.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context.parsedResult)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context.parsedResult)
  if (!result) return null

  const input = isPlainObject(context.input) ? context.input : {}
  const jobId = displayValue(input.job_id)
  const event = displayValue(input.event)

  return (
    <div className="space-y-1">
      {jobId || event ? (
        <div className="flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-300">
          {jobId ? <JobRefLink jobId={jobId} /> : null}
          {event ? <Badge>{event}</Badge> : null}
        </div>
      ) : null}
      <PendingActionResultCard result={result} />
    </div>
  )
}

const forceStateTransitionToolCard: ToolCardRenderer = {
  toolName: "force_state_transition",
  collapsedSummary,
  renderExpanded
}

export default forceStateTransitionToolCard
