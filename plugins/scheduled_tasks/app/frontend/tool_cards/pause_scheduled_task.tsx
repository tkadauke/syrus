import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseScheduledTaskOutcome, ScheduledTaskOutcomeCard } from "../scheduledTaskToolCard"

// Plugin-owned tool card for pause_scheduled_task (EPIC-292 / JOB-4222).
// Payload: { scheduled_task_id, label, enabled: false }.
function collapsedSummary(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return `Paused '${outcome.label}' (#${outcome.id})`
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return (
    <ScheduledTaskOutcomeCard
      detail="This task will not fire again until it is resumed."
      outcome={outcome}
      pill="paused"
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
