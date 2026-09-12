import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseScheduledTaskOutcome, ScheduledTaskOutcomeCard, t } from "../scheduledTaskToolCard"

// Plugin-owned tool card for resume_scheduled_task (the pending-action tool-card work).
// Payload: { scheduled_task_id, label, enabled: true }.
function collapsedSummary(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return t("tool_resumed_summary", { label: outcome.label, id: outcome.id })
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return (
    <ScheduledTaskOutcomeCard
      detail={t("tool_resumed_detail")}
      outcome={outcome}
      pill={t("tool_resumed")}
      tone="success"
    />
  )
}

const resumeScheduledTaskToolCard: ToolCardRenderer = {
  toolName: "resume_scheduled_task",
  collapsedSummary,
  renderExpanded
}

export default resumeScheduledTaskToolCard
