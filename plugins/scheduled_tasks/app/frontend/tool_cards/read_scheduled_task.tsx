import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell } from "@app/routes/chat/toolCardUi"
import {
  parseScheduledTaskDetail,
  PromptDisclosure,
  scheduledTaskHeadline,
  ScheduledTaskSummary
} from "../scheduledTaskToolCard"

// Plugin-owned tool card for read_scheduled_task (EPIC-292 / JOB-4222).
// Payload is `{ scheduled_task: <scheduled_task_payload>.merge(prompt:) }`;
// the prompt is usually long, so it hides behind a disclosure.
function collapsedSummary(context: ToolCardContext) {
  const detail = parseScheduledTaskDetail(context.parsedResult)
  if (!detail) return null

  return scheduledTaskHeadline(detail.task)
}

function renderExpanded(context: ToolCardContext) {
  const detail = parseScheduledTaskDetail(context.parsedResult)
  if (!detail) return null

  return (
    <CardShell>
      <ScheduledTaskSummary task={detail.task} />
      {detail.prompt ? <PromptDisclosure prompt={detail.prompt} /> : null}
    </CardShell>
  )
}

const readScheduledTaskToolCard: ToolCardRenderer = {
  toolName: "read_scheduled_task",
  collapsedSummary,
  renderExpanded
}

export default readScheduledTaskToolCard
