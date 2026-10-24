import type { ReactNode } from "react"
import i18n from "i18next"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { ErrorCard } from "@app/routes/chat/chatHelperToolCard"
import { Badge, CardShell, displayValue, EntityReference, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import type { MarkdownLinkHandler } from "@app/lib/Markdown"

// Shared presentation helpers for the scheduled_tasks plugin's chat tool
// cards (the pending-action tool-card work). Lives outside `tool_cards/` on purpose: core's
// pluginToolCards.tsx glob treats every non-test .tsx file under
// `tool_cards/` as a card module and warns about a missing default export
// (same reason core keeps toolCardUi.tsx one directory up).
//
// `scheduled_task_payload` (see
// plugins/scheduled_tasks/app/services/scheduled_tasks/mcp_tools/scheduled_task_tool_support.rb)
// is emitted by list_scheduled_tasks, read_scheduled_task, and
// update_scheduled_task, so all three parse and render it through here.
export type ScheduledTaskCard = {
  id: string
  label: string
  state: string
  kind: string | null
  repositoryId: string | null
  repositorySlug: string | null
  cadence: string | null
  cronExpression: string | null
  scheduleInput: string | null
  scheduleExpression: string | null
  scheduleExplanation: string | null
  scheduleTimezone: string | null
  prPileupPolicy: string | null
  enabled: boolean | null
  fireAt: string | null
  nextFireAt: string | null
  lastFiredAt: string | null
  lastSuccessfulFireAt: string | null
  createdAt: string | null
  consecutiveFailureCount: number
}

export function parseScheduledTask(value: unknown): ScheduledTaskCard | null {
  if (!isPlainObject(value)) return null

  const id = displayValue(value.id)
  const label = displayValue(value.label)
  const state = displayValue(value.state)
  if (!id || !label || !state) return null

  const fireAt = displayValue(value.fire_at)
  const cadence =
    displayValue(value.schedule_explanation) ||
    displayValue(value.cron_expression) ||
    displayValue(value.schedule_input) ||
    displayValue(value.schedule_expression) ||
    (fireAt ? t("tool_once_at", { time: fireAt }) : null)

  return {
    id,
    label,
    state,
    kind: displayValue(value.kind),
    repositoryId: displayValue(value.repository_id),
    repositorySlug: displayValue(value.repository_slug),
    cadence,
    cronExpression: displayValue(value.cron_expression),
    scheduleInput: displayValue(value.schedule_input),
    scheduleExpression: displayValue(value.schedule_expression),
    scheduleExplanation: displayValue(value.schedule_explanation),
    scheduleTimezone: displayValue(value.schedule_timezone),
    prPileupPolicy: displayValue(value.pr_pileup_policy),
    enabled: typeof value.enabled === "boolean" ? value.enabled : null,
    fireAt,
    nextFireAt: displayValue(value.next_fire_at),
    lastFiredAt: displayValue(value.last_fired_at),
    lastSuccessfulFireAt: displayValue(value.last_successful_fire_at),
    createdAt: displayValue(value.created_at),
    consecutiveFailureCount: numberValue(value.consecutive_failure_count) ?? 0
  }
}

// Parses `{ "scheduled_task": { ...payload, prompt: "..." } }`, the shape
// read_scheduled_task and update_scheduled_task both return.
export function parseScheduledTaskDetail(parsed: unknown): { task: ScheduledTaskCard; prompt: string | null; hasPrompt: boolean } | null {
  if (!isPlainObject(parsed)) return null

  const task = parseScheduledTask(parsed.scheduled_task)
  if (!task) return null

  const payload = parsed.scheduled_task
  const hasPrompt = isPlainObject(payload) && Object.prototype.hasOwnProperty.call(payload, "prompt")
  const prompt = isPlainObject(payload) && typeof payload.prompt === "string" ? payload.prompt : null
  return { task, prompt, hasPrompt }
}

export function scheduledTaskHeadline(task: ScheduledTaskCard) {
  return `${task.label} (#${task.id}, ${task.state})`
}

export function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`scheduled_tasks:${key}`, options)
}

export function scheduledTaskErrorMessage(context: ToolCardContext): string | null {
  if (!context.resultError) return null
  if (isPlainObject(context.parsedResult)) {
    const nested = isPlainObject(context.parsedResult.error) ? context.parsedResult.error : null
    return displayValue(nested?.message) || displayValue(context.parsedResult.message) || displayValue(context.parsedResult.error) || t("tool_error_fallback")
  }
  return displayValue(context.resultBody) || t("tool_error_fallback")
}

export function withScheduledTaskErrors(renderer: ToolCardRenderer, title = t("tool_error_title")): ToolCardRenderer {
  return {
    ...renderer,
    collapsedSummary(context) {
      return scheduledTaskErrorMessage(context) ? t("tool_error_summary") : renderer.collapsedSummary?.(context)
    },
    renderExpanded(context) {
      const message = scheduledTaskErrorMessage(context)
      return message ? <ErrorCard message={message} title={title} /> : renderer.renderExpanded(context)
    }
  }
}

export function FailureBadge({ count }: { count: number }) {
  if (count <= 0) return null

  return (
    <span className="rounded-full bg-amber-100 px-2 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
      {t("tool_consecutive_failures", { count })}
    </span>
  )
}

export function ScheduledTaskSummary({ task }: { task: ScheduledTaskCard }) {
  const nextFire = task.nextFireAt || task.fireAt

  return (
    <>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={task.id} kind="scheduled_task" wrap="nowrap" />
        <StatePill state={task.state} />
        {task.kind ? <Badge>{task.kind.replace(/_/g, " ")}</Badge> : null}
        {task.enabled === false ? <Badge>{t("tool_disabled")}</Badge> : null}
        <FailureBadge count={task.consecutiveFailureCount} />
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{task.label}</div>
      <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
        {task.cadence ? (
          <Row label={t("tool_col_cadence")} value={task.scheduleTimezone ? `${task.cadence} (${task.scheduleTimezone})` : task.cadence} />
        ) : null}
        {task.scheduleInput && task.scheduleInput !== task.cadence ? <Row label={t("tool_schedule_input")} value={task.scheduleInput} /> : null}
        {task.cronExpression && task.cronExpression !== task.cadence ? <Row label={t("tool_resolved_cron")} value={task.cronExpression} /> : null}
        {task.scheduleExpression && ![task.cadence, task.scheduleInput, task.cronExpression].includes(task.scheduleExpression) ? (
          <Row label={t("tool_schedule_expression")} value={task.scheduleExpression} />
        ) : null}
        {task.repositorySlug ? (
          <div className="min-w-0">
            <div className="text-2xs font-semibold uppercase tracking-wide text-text-muted">{t("tool_repository")}</div>
            <EntityReference kind="repository" repositoryId={task.repositoryId} repositorySlug={task.repositorySlug} />
          </div>
        ) : null}
        {nextFire ? <DateTimeRow label={t("tool_col_next_fire")} value={nextFire} /> : null}
        {task.lastFiredAt ? <DateTimeRow label={t("tool_last_fired")} value={task.lastFiredAt} /> : null}
        {task.lastSuccessfulFireAt ? <DateTimeRow label={t("tool_last_success")} value={task.lastSuccessfulFireAt} /> : null}
        {task.prPileupPolicy ? <Row label={t("tool_pr_pileup")} value={task.prPileupPolicy} /> : null}
        {task.createdAt ? <DateTimeRow label={t("tool_created_at")} value={task.createdAt} /> : null}
      </dl>
    </>
  )
}

// Compact Markdown prompt preview shared by read/update cards.
function DateTimeRow({ label, value }: { label: string; value: string }) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return <Row label={label} value={value} />

  const local = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date)
  const utc = new Intl.DateTimeFormat(undefined, {
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    month: "short",
    timeZone: "UTC",
    timeZoneName: "short",
    year: "numeric"
  }).format(date)

  return (
    <div className="min-w-0 py-1">
      <dt className="text-2xs font-semibold uppercase tracking-wide text-text-muted">{label}</dt>
      <dd className="min-w-0 break-words text-xs text-text-primary [overflow-wrap:anywhere]">
        <time dateTime={value}>{local}</time>
        <span className="block text-text-muted">{t("tool_utc_time", { time: utc })}</span>
      </dd>
    </div>
  )
}

export function PromptPreview({ onLinkClick, prompt }: { onLinkClick?: MarkdownLinkHandler; prompt: string | null }) {
  return (
    <MarkdownPreview
      emptyLabel={t("tool_prompt_empty")}
      linkifySlugs
      linkifyUrls
      maxChars={720}
      modalLabel={t("tool_prompt_full")}
      onLinkClick={onLinkClick}
      text={prompt}
      title={t("tool_prompt")}
    />
  )
}

export const PromptDisclosure = PromptPreview

// pause/resume/delete all answer with the same tiny
// `{ scheduled_task_id, label, ... }` acknowledgement shape.
export type ScheduledTaskOutcome = {
  id: string
  label: string
  previousState: string | null
  state: string | null
  nextFireAt: string | null
  repositoryId: string | null
  repositorySlug: string | null
}

export function parseScheduledTaskOutcome(parsed: unknown): ScheduledTaskOutcome | null {
  if (!isPlainObject(parsed)) return null

  // Newer write tools may return the task in a named envelope. Keep accepting
  // the original flat acknowledgement used by pause/resume/delete.
  const payload = isPlainObject(parsed.scheduled_task) ? parsed.scheduled_task : parsed
  const id = displayValue(payload.scheduled_task_id) || displayValue(payload.id)
  const label = displayValue(payload.label) || displayValue(payload.name)
  if (!id || !label) return null

  return {
    id,
    label,
    previousState: displayValue(payload.previous_state),
    state: displayValue(payload.state),
    nextFireAt: displayValue(payload.next_fire_at),
    repositoryId: displayValue(payload.repository_id),
    repositorySlug: displayValue(payload.repository_slug)
  }
}

export function ScheduledTaskOutcomeCard({
  outcome,
  pill,
  tone,
  detail
}: {
  outcome: ScheduledTaskOutcome
  pill: string
  tone?: "success" | "failure" | "warning" | "info" | "neutral"
  detail?: ReactNode
}) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={pill} tone={tone} />
        <EntityReference id={outcome.id} kind="scheduled_task" wrap="nowrap" />
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{outcome.label}</div>
      {detail ? <div className="text-gray-600 dark:text-gray-300">{detail}</div> : null}
    </CardShell>
  )
}
