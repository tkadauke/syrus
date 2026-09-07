import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseScheduledTaskOutcome, ScheduledTaskOutcomeCard } from "../scheduledTaskToolCard"

// Plugin-owned tool card for resume_scheduled_task (EPIC-292 / JOB-4222).
// Payload: { scheduled_task_id, label, enabled: true }.
function collapsedSummary(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return `Resumed '${outcome.label}' (#${outcome.id})`
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return (
    <ScheduledTaskOutcomeCard
      detail="This task is scheduled again and will fire on its next due tick."
      outcome={outcome}
      pill="resumed"
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
