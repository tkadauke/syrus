import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { intlLocale, formatRelativeDate } from "../../../lib/relativeTime"
import { MarkdownPreview } from "../toolCardMarkdown"
import { CardShell, displayValue, EntityReference, numberValue, Row, StatePill } from "../toolCardUi"

// Core-owned tool card for schedule_wakeup (the pending-action tool-card work).
type ScheduleWakeupCard = {
  wakeupId: string | null
  fireAt: string | null
  prompt: string
  delayMinutes: number | null
  message: string | null
  error: string | null
  pending: boolean
}

function errorMessage(context: ToolCardContext) {
  const parsed = context.parsedResult
  if (isPlainObject(parsed)) {
    for (const key of ["message", "error", "detail", "reason"]) {
      const value = displayValue(parsed[key])
      if (value) return value
    }
  }
  return displayValue(context.resultBody) ?? "The wakeup could not be scheduled."
}

function parseScheduleWakeup(context: ToolCardContext): ScheduleWakeupCard {
  const parsed = context.parsedResult
  const result = isPlainObject(parsed) ? parsed : {}
  return {
    wakeupId: displayValue(result.wakeup_id),
    fireAt: displayValue(result.fire_at) ?? displayValue(context.input?.fire_at),
    prompt: displayValue(context.input?.prompt) ?? "",
    delayMinutes: numberValue(context.input?.delay_minutes),
    message: displayValue(result.message),
    error: context.resultError ? errorMessage(context) : null,
    pending: !context.resultError && !displayValue(result.wakeup_id)
  }
}

function validDate(value: string | null) {
  if (!value) return null
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? null : date
}

function localFireTime(value: string) {
  return new Intl.DateTimeFormat(intlLocale(), { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseScheduleWakeup(context)
  if (result.error) return `Wakeup scheduling failed: ${result.error}`
  const fireDate = validDate(result.fireAt)
  if (result.wakeupId && fireDate) return `Wakeup scheduled ${formatRelativeDate(fireDate)}`
  if (result.pending) return "Scheduling wakeup..."
  return null
}

function renderExpanded(context: ToolCardContext) {
  const result = parseScheduleWakeup(context)
  const fireDate = validDate(result.fireAt)

  return (
    <CardShell tone={result.error ? "danger" : result.pending ? "info" : "success"}>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={result.error ? "failed" : result.pending ? "pending" : "scheduled"} />
        {result.wakeupId ? <EntityReference id={result.wakeupId} kind="wakeup" /> : null}
      </div>
      {result.error ? <div className="break-words text-danger-text [overflow-wrap:anywhere]">{result.error}</div> : null}
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        {fireDate && result.fireAt ? (
          <div className="min-w-0 sm:col-span-2">
            <div className="text-2xs font-semibold uppercase text-text-muted">Fires at</div>
            <div className="flex min-w-0 flex-wrap gap-x-2 gap-y-1 text-xs text-text-primary">
              <time dateTime={result.fireAt}>{localFireTime(result.fireAt)}</time>
              <span className="text-text-muted">({formatRelativeDate(fireDate)})</span>
              <span className="break-all font-mono text-text-muted">{fireDate.toISOString()} UTC</span>
            </div>
          </div>
        ) : result.fireAt ? (
          <Row label="Fires at" value={result.fireAt} />
        ) : null}
        {result.delayMinutes != null ? <Row label="Delay" value={`${result.delayMinutes} minutes`} /> : null}
        {result.message ? <Row label="Result" value={result.message} /> : null}
      </dl>
      <MarkdownPreview emptyLabel="No prompt provided." linkifyUrls maxChars={640} text={result.prompt} title="Prompt" />
    </CardShell>
  )
}

const scheduleWakeupToolCard: ToolCardRenderer = {
  toolName: "schedule_wakeup",
  collapsedSummary,
  renderExpanded
}

export default scheduleWakeupToolCard

export const examples: ToolCardExample[] = [
  {
    id: "scheduled_absolute",
    label: "Scheduled for an absolute time",
    input: { prompt: "Check **JOB-42** and review https://example.test/status.", fire_at: "2026-12-01T15:30:00Z" },
    parsedResult: { wakeup_id: 17, fire_at: "2026-12-01T15:30:00Z", message: "Wakeup scheduled for 2026-12-01T15:30:00Z" }
  },
  {
    id: "validation_error",
    label: "Validation error",
    input: { prompt: "Check again." },
    resultBody: "provide exactly one of delay_minutes or fire_at",
    resultError: true
  }
]
