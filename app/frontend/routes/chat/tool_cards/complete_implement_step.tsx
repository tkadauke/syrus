import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
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

export const examples: ToolCardExample[] = [
  {
    id: "pending_with_branch",
    label: "Pending handoff with branch",
    description: "Shows the linked Job, a long copyable branch, and a Markdown confirmation message across responsive layouts.",
    input: { job_id: 4048, branch_name: "syrus/complete-implement-step-responsive-card-review" },
    parsedResult: {
      pending_confirmation_id: 501,
      pending_action_id: 501,
      state: "pending",
      message: "Review the **implementation handoff** before confirming."
    }
  },
  {
    id: "rejected_active_checkout",
    label: "Rejected active-checkout handoff",
    description: "Shows the omitted-branch label and a settled rejection while retaining the requested Job.",
    input: { job_id: 4048 },
    parsedResult: {
      pending_confirmation_id: 502,
      pending_action_id: 502,
      state: "rejected",
      message: "The **active checkout branch** was not handed off."
    }
  },
  {
    id: "tool_error",
    label: "Handoff validation error",
    description: "Shows a plain-text tool error with the submitted Job and active-checkout branch context.",
    input: { job_id: 4048 },
    resultBody: "Error: branch_name is required for Jobs without an existing pull request.",
    resultError: true
  }
]
