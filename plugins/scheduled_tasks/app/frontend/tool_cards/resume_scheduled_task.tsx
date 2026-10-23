import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { intlLocale } from "@app/lib/relativeTime"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { ErrorCard } from "@app/routes/chat/chatHelperToolCard"
import { CardShell, displayValue, EntityReference, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { parseScheduledTask, parseScheduledTaskOutcome, t, scheduledTaskErrorMessage, type ScheduledTaskCard } from "../scheduledTaskToolCard"

// Plugin-owned tool card for resume_scheduled_task (the pending-action tool-card work).
// Payload: { scheduled_task_id, label, enabled: true }.
function collapsedSummary(context: ToolCardContext) {
  if (scheduledTaskErrorMessage(context)) return t("tool_error_summary")
  const outcome = parseResumeOutcome(context.parsedResult)
  if (!outcome) return null

  return t("tool_resumed_summary", { label: outcome.label, id: outcome.id })
}

function parseResumeOutcome(parsed: unknown): { id: string; label: string; task: ScheduledTaskCard | null } | null {
  if (!isPlainObject(parsed)) return null
  const task = parseScheduledTask(parsed.scheduled_task) || parseScheduledTask({ ...parsed, id: parsed.scheduled_task_id }) || parseScheduledTask(parsed)
  if (task) return { id: task.id, label: task.label, task }

  const outcome = parseScheduledTaskOutcome(parsed)
  return outcome ? { ...outcome, task: null } : null
}

function exactTimes(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return null

  return {
    local: new Intl.DateTimeFormat(intlLocale(), { dateStyle: "medium", timeStyle: "long" }).format(date),
    utc: new Intl.DateTimeFormat(intlLocale(), {
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
      month: "short",
      second: "2-digit",
      timeZone: "UTC",
      timeZoneName: "short",
      year: "numeric"
    }).format(date)
  }
}

function RequestedTask({ context }: { context: ToolCardContext }) {
  const id = displayValue(context.input?.scheduled_task_id)
  return id ? <EntityReference id={id} kind="scheduled_task" wrap="nowrap" /> : null
}

function renderExpanded(context: ToolCardContext) {
  const error = scheduledTaskErrorMessage(context)
  if (error)
    return (
      <ErrorCard message={error} title={t("tool_resume_error_title")}>
        <RequestedTask context={context} />
      </ErrorCard>
    )

  const outcome = parseResumeOutcome(context.parsedResult)
  if (!outcome) return null
  if (!outcome.task)
    return (
      <CardShell>
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <StatePill state={t("tool_resumed")} tone="success" />
          <EntityReference id={outcome.id} kind="scheduled_task" wrap="nowrap" />
        </div>
        <div className="min-w-0 break-words text-sm font-medium text-text-primary">{outcome.label}</div>
        <div className="text-text-secondary">{t("tool_resumed_detail")}</div>
      </CardShell>
    )

  const times = outcome.task.nextFireAt ? exactTimes(outcome.task.nextFireAt) : null

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={outcome.task.state} />
        <EntityReference id={outcome.id} kind="scheduled_task" wrap="nowrap" />
      </div>
      <div className="min-w-0 break-words text-sm font-medium text-text-primary">{outcome.label}</div>
      <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
        {outcome.task.repositorySlug ? (
          <div className="min-w-0">
            <div className="text-2xs font-semibold uppercase tracking-wide text-text-muted">{t("tool_repository")}</div>
            <EntityReference kind="repository" repositoryId={outcome.task.repositoryId} repositorySlug={outcome.task.repositorySlug} />
          </div>
        ) : null}
        {outcome.task.nextFireAt ? <Row label={t("tool_next_fire_relative")} value={<RelativeTimestamp value={outcome.task.nextFireAt} />} /> : null}
        {times ? <Row label={t("tool_next_fire_local")} value={times.local} /> : null}
        {times ? <Row label={t("tool_next_fire_utc")} value={times.utc} /> : null}
      </dl>
      <div className="text-text-secondary">{t("tool_resumed_detail")}</div>
    </CardShell>
  )
}

const resumeScheduledTaskToolCard: ToolCardRenderer = {
  toolName: "resume_scheduled_task",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "resumed_with_next_fire",
    label: "Resumed task with next fire",
    input: { scheduled_task_id: 12 },
    parsedResult: {
      scheduled_task_id: 12,
      label: "Nightly main-branch health check",
      enabled: true,
      state: "scheduled",
      repository_id: 8,
      repository_slug: "tkadauke/syrus",
      next_fire_at: "2026-10-24T03:00:00Z"
    }
  },
  {
    id: "already_enabled_error",
    label: "Already enabled error",
    input: { scheduled_task_id: 12 },
    resultBody: "scheduled task is already enabled",
    resultError: true
  }
]

export default resumeScheduledTaskToolCard
