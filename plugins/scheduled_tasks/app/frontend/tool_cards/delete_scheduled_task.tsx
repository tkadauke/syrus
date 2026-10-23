import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EntityReference, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { t, withScheduledTaskErrors } from "../scheduledTaskToolCard"

// Plugin-owned tool card for delete_scheduled_task (the pending-action tool-card work).
// Payload: { scheduled_task_id, label, repository_slug, schedule_explanation,
// schedule_timezone, deleted: true }.
type DeletedScheduledTask = {
  id: string
  label: string
  repositoryId: string | null
  repositorySlug: string | null
  schedule: string | null
  scheduleTimezone: string | null
}

function parseDeletedScheduledTask(parsed: unknown): DeletedScheduledTask | null {
  if (!isPlainObject(parsed)) return null

  // Accept the flat acknowledgement and a nested task snapshot so the card
  // remains provider-agnostic if an MCP client preserves that envelope.
  const value = isPlainObject(parsed.scheduled_task) ? parsed.scheduled_task : parsed
  const id = displayValue(value.scheduled_task_id) || displayValue(value.id)
  const label = displayValue(value.label)
  if (!id || !label) return null

  return {
    id,
    label,
    repositoryId: displayValue(value.repository_id),
    repositorySlug: displayValue(value.repository_slug),
    schedule: displayValue(value.schedule_explanation) || displayValue(value.schedule_input) || displayValue(value.cron_expression),
    scheduleTimezone: displayValue(value.schedule_timezone)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const outcome = parseDeletedScheduledTask(context.parsedResult)
  if (!outcome) return null

  return t("tool_deleted_summary", { label: outcome.label, id: outcome.id })
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseDeletedScheduledTask(context.parsedResult)
  if (!outcome) return null

  const schedule = outcome.schedule && outcome.scheduleTimezone ? `${outcome.schedule} (${outcome.scheduleTimezone})` : outcome.schedule

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={t("tool_deleted")} tone="failure" />
        <EntityReference id={`TASK-${outcome.id}`} kind="artifact" wrap="nowrap" />
      </div>
      <div className="break-words text-sm font-medium text-gray-900 dark:text-gray-100">{outcome.label}</div>
      <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
        {outcome.repositorySlug ? (
          <div className="min-w-0">
            <div className="text-2xs font-semibold uppercase tracking-wide text-text-muted">{t("tool_repository")}</div>
            <EntityReference kind="repository" repositoryId={outcome.repositoryId} repositorySlug={outcome.repositorySlug} />
          </div>
        ) : null}
        {schedule ? <Row label={t("tool_col_cadence")} value={schedule} /> : null}
      </dl>
      <div className="break-words text-gray-600 dark:text-gray-300">{t("tool_deleted_detail")}</div>
    </CardShell>
  )
}

const deleteScheduledTaskToolCard: ToolCardRenderer = withScheduledTaskErrors({
  toolName: "delete_scheduled_task",
  collapsedSummary,
  renderExpanded
})

export default deleteScheduledTaskToolCard

export const examples: ToolCardExample[] = [
  {
    id: "deleted_task_details",
    label: "Deleted scheduled task",
    input: { scheduled_task_id: 12 },
    parsedResult: {
      scheduled_task_id: 12,
      label: "Nightly main-branch health check",
      repository_id: 7,
      repository_slug: "acme/widgets",
      schedule_explanation: "Every day at 02:00 UTC",
      schedule_timezone: "UTC",
      deleted: true
    }
  },
  {
    id: "task_not_found",
    label: "Task not found",
    input: { scheduled_task_id: 404 },
    resultBody: "scheduled task not found: 404",
    resultError: true
  }
]
