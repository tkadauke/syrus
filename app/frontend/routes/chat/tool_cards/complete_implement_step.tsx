import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import i18n from "@app/i18n"

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
        { key: "job_id", label: () => i18n.t("chat:complete_implement_step.job"), format: "entity", entityKind: "job" },
        {
          key: "branch_name",
          label: () => i18n.t("chat:complete_implement_step.branch"),
          format: "copyable_badge",
          emptyLabel: i18n.t("chat:complete_implement_step.active_checkout_branch")
        }
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
    label: i18n.t("chat:complete_implement_step.example_pending"),
    description: i18n.t("chat:complete_implement_step.example_pending_description"),
    input: { job_id: 4048, branch_name: "syrus/complete-implement-step-responsive-card-review" },
    parsedResult: {
      pending_confirmation_id: 501,
      pending_action_id: 501,
      state: "pending",
      message: i18n.t("chat:complete_implement_step.example_pending_message")
    }
  },
  {
    id: "rejected_active_checkout",
    label: i18n.t("chat:complete_implement_step.example_rejected"),
    description: i18n.t("chat:complete_implement_step.example_rejected_description"),
    input: { job_id: 4048 },
    parsedResult: {
      pending_confirmation_id: 502,
      pending_action_id: 502,
      state: "rejected",
      message: i18n.t("chat:complete_implement_step.example_rejected_message")
    }
  },
  {
    id: "tool_error",
    label: i18n.t("chat:complete_implement_step.example_error"),
    description: i18n.t("chat:complete_implement_step.example_error_description"),
    input: { job_id: 4048 },
    resultBody: "Error: branch_name is required for Jobs without an existing pull request.",
    resultError: true
  }
]
