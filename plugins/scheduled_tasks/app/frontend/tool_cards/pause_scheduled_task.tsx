import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseScheduledTaskOutcome, ScheduledTaskOutcomeCard, t } from "../scheduledTaskToolCard"

// Plugin-owned tool card for pause_scheduled_task (the pending-action tool-card work).
// Payload: { scheduled_task_id, label, enabled: false }.
function collapsedSummary(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return t("tool_paused_summary", { label: outcome.label, id: outcome.id })
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return (
    <ScheduledTaskOutcomeCard
      detail={t("tool_paused_detail")}
      outcome={outcome}
      pill={t("tool_paused")}
      tone="warning"
    />
  )
}

const pauseScheduledTaskToolCard: ToolCardRenderer = {
  toolName: "pause_scheduled_task",
  collapsedSummary,
  renderExpanded
}

export default pauseScheduledTaskToolCard
