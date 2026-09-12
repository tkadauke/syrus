import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "i18next"
import { CardShell } from "@app/routes/chat/toolCardUi"
import { parseScheduledTaskDetail, PromptDisclosure, ScheduledTaskSummary } from "../scheduledTaskToolCard"

// Plugin-owned tool card for update_scheduled_task (the pending-action tool-card work).
// The tool answers with the same `{ scheduled_task: ... }` snapshot
// read_scheduled_task returns, so the card body is the post-update state;
// only the collapsed summary names the outcome.
function collapsedSummary(context: ToolCardContext) {
  const detail = parseScheduledTaskDetail(context.parsedResult)
  if (!detail) return null

  return t("tool_update_summary", { label: detail.task.label, id: detail.task.id })
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`scheduled_tasks:${key}`, options)
}

function renderExpanded(context: ToolCardContext) {
  const detail = parseScheduledTaskDetail(context.parsedResult)
  if (!detail) return null

  return (
    <CardShell>
      <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("tool_update_title")}</div>
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
