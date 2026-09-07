import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell } from "@app/routes/chat/toolCardUi"
import { parseScheduledTaskDetail, PromptDisclosure, ScheduledTaskSummary } from "../scheduledTaskToolCard"

// Plugin-owned tool card for update_scheduled_task (EPIC-292 / JOB-4222).
// The tool answers with the same `{ scheduled_task: ... }` snapshot
// read_scheduled_task returns, so the card body is the post-update state;
// only the collapsed summary names the outcome.
function collapsedSummary(context: ToolCardContext) {
  const detail = parseScheduledTaskDetail(context.parsedResult)
  if (!detail) return null

  return `Updated ${detail.task.label} (#${detail.task.id})`
}

function renderExpanded(context: ToolCardContext) {
  const detail = parseScheduledTaskDetail(context.parsedResult)
  if (!detail) return null

  return (
    <CardShell>
      <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">Updated scheduled task</div>
      <ScheduledTaskSummary task={detail.task} />
      {detail.prompt ? <PromptDisclosure prompt={detail.prompt} /> : null}
    </CardShell>
  )
}

const updateScheduledTaskToolCard: ToolCardRenderer = {
  toolName: "update_scheduled_task",
  collapsedSummary,
  renderExpanded
}

export default updateScheduledTaskToolCard
