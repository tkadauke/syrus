import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import i18n from "@app/i18n"

function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  if (!result) return null

  return <PendingActionResultCard result={result} />
}

const emergencyLandToolCard: ToolCardRenderer = {
  toolName: "emergency_land",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: i18n.t("chat:emergency_land.example_pending"),
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
