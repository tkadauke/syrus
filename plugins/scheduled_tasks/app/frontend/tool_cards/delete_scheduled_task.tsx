import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseScheduledTaskOutcome, ScheduledTaskOutcomeCard } from "../scheduledTaskToolCard"

// Plugin-owned tool card for delete_scheduled_task (EPIC-292 / JOB-4222).
// Payload: { scheduled_task_id, label, deleted: true }.
function collapsedSummary(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return `Deleted '${outcome.label}' (#${outcome.id})`
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return (
    <ScheduledTaskOutcomeCard
      detail="The task was removed and will never fire again."
      outcome={outcome}
      pill="deleted"
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
