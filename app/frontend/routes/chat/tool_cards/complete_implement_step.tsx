import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"

// Core-owned tool card for complete_implement_step. Reuses the shared
// pending-action parsing/rendering, which preserves target context from the
// tool call when the result only carries the confirmation shape.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  if (!result) return null

  return (
    <PendingActionResultCard
      input={context.input}
      inputFields={[
        { key: "job_id", label: "Job", format: "entity", entityKind: "job" },
        { key: "branch_name", label: "Branch", format: "copyable_badge", emptyLabel: "Active checkout branch" }
      ]}
      omitBranch
      omitJob
      result={result}
    />
  )
}

const completeImplementStepToolCard: ToolCardRenderer = {
  toolName: "complete_implement_step",
  collapsedSummary,
  renderExpanded
}

export default completeImplementStepToolCard
