import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseScheduledTaskOutcome, ScheduledTaskOutcomeCard, t } from "../scheduledTaskToolCard"

// Plugin-owned tool card for delete_scheduled_task (the pending-action tool-card work).
// Payload: { scheduled_task_id, label, deleted: true }.
function collapsedSummary(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return t("tool_deleted_summary", { label: outcome.label, id: outcome.id })
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return (
    <ScheduledTaskOutcomeCard
      detail={t("tool_deleted_detail")}
      outcome={outcome}
      pill={t("tool_deleted")}
      tone="failure"
    />
  )
}

const deleteScheduledTaskToolCard: ToolCardRenderer = {
  toolName: "delete_scheduled_task",
  collapsedSummary,
  renderExpanded
}

export default deleteScheduledTaskToolCard
