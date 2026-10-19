import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { ErrorCard } from "@app/routes/chat/chatHelperToolCard"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { CardShell, displayValue, EntityReference, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { scheduledTaskErrorMessage, t } from "../scheduledTaskToolCard"

type ScheduleRecurringCard = {
  confirmationId: string
  label: string | null
  prompt: string | null
  scheduleInput: string | null
  cronExpression: string | null
  explanation: string | null
  nextFireAt: string | null
  state: string
  reason: string | null
  taskId: string | null
  taskHref: string | null
}

function parseScheduleRecurring(context: ToolCardContext): ScheduleRecurringCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const confirmationId = displayValue(parsed.pending_confirmation_id) || displayValue(parsed.pending_action_id)
  if (!confirmationId) return null

  const input = isPlainObject(context.input) ? context.input : {}
  const live = context.livePendingAction
  const liveMatch = live && displayValue(live.id) === confirmationId ? live : null
  const resourceMatch = liveMatch?.resource_url?.match(/^\/scheduled_tasks\/(\d+)$/)
  const resultId = displayValue(liveMatch?.after_snapshot?.id)

  return {
    confirmationId,
    label: displayValue(parsed.label) || displayValue(input.label),
    prompt: displayValue(parsed.prompt) || displayValue(input.prompt),
    scheduleInput: displayValue(parsed.schedule_input) || displayValue(input.schedule_input) || displayValue(input.cron_expression),
    cronExpression: displayValue(parsed.cron_expression),
    explanation: displayValue(parsed.schedule_explanation),
    nextFireAt: displayValue(parsed.next_fire_at),
    state: liveMatch?.state || displayValue(parsed.state) || "pending",
    reason: displayValue(liveMatch?.reason) || displayValue(liveMatch?.execution_error),
    taskId: resourceMatch?.[1] || resultId,
    taskHref: liveMatch?.resource_url || (resultId ? `/scheduled_tasks/${resultId}` : null)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const error = scheduledTaskErrorMessage(context)
  if (error) return t("tool_schedule_error_summary")
  const card = parseScheduleRecurring(context)
  if (!card) return null
  if (card.state === "confirmed") return t("tool_schedule_confirmed_summary", { label: card.label || card.confirmationId })
  if (card.state === "rejected") return t("tool_schedule_rejected_summary", { label: card.label || card.confirmationId })
  return card.explanation
    ? t("tool_schedule_summary_with_explanation", { explanation: card.explanation })
    : t("tool_schedule_summary_with_confirmation", { id: card.confirmationId })
}

function renderExpanded(context: ToolCardContext) {
  const error = scheduledTaskErrorMessage(context)
  if (error) return <ErrorCard message={error} title={t("tool_schedule_title")} />
  const card = parseScheduleRecurring(context)
  if (!card) return null
  const pending = ["queued", "pending", "confirming"].includes(card.state)

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={card.state} />
        <span className="min-w-0 break-words text-sm font-medium text-gray-900 dark:text-gray-100">{card.label || t("tool_schedule_title")}</span>
        <EntityReference id={card.confirmationId} kind="pending_action" wrap="nowrap" />
        {card.taskId ? <EntityReference href={card.taskHref} id={card.taskId} kind="scheduled_task" wrap="nowrap" /> : null}
      </div>
      {card.prompt != null ? (
        <MarkdownPreview emptyLabel={t("tool_prompt_empty")} maxChars={720} modalLabel={t("tool_prompt_full")} text={card.prompt} title={t("tool_prompt")} />
      ) : null}
      <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
        {card.scheduleInput ? <Row label={t("tool_schedule_input")} value={card.scheduleInput} /> : null}
        {card.cronExpression ? <Row label={t("tool_resolved_cron")} value={card.cronExpression} /> : null}
        {card.explanation ? <Row label={t("tool_col_cadence")} value={card.explanation} /> : null}
        {card.nextFireAt ? <Row label={t("tool_first_fire")} value={card.nextFireAt} /> : null}
      </dl>
      {card.scheduleInput || card.cronExpression ? <div className="text-gray-500 dark:text-gray-400">{t("tool_interpreted_utc")}</div> : null}
      {pending ? <div className="text-gray-500 dark:text-gray-400">{t("tool_schedule_pending_confirmation")}</div> : null}
      {card.state === "confirmed" && card.taskId ? <div className="text-success-text">{t("tool_schedule_created")}</div> : null}
      {card.state === "rejected" ? <div className="text-danger-text">{card.reason || t("tool_schedule_rejected")}</div> : null}
    </CardShell>
  )
}

const scheduleRecurringToolCard: ToolCardRenderer = { toolName: "schedule_recurring", collapsedSummary, renderExpanded }

export const examples: ToolCardExample[] = [
  {
    id: "pending_markdown_prompt",
    label: "Pending recurring task",
    input: { label: "Weekly review", prompt: "Review **open work** and link JOB-42.", schedule_input: "Every Monday at 9:00 AM" },
    parsedResult: {
      pending_confirmation_id: 501,
      schedule_explanation: "Runs every Monday at 9:00 AM UTC",
      cron_expression: "0 9 * * 1",
      next_fire_at: "2026-09-08T09:00:00Z"
    }
  },
  { id: "write_access_error", label: "Write access error", resultBody: "repository write access is required to create a scheduled task", resultError: true }
]

export default scheduleRecurringToolCard
