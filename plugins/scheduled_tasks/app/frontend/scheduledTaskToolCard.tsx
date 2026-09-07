import type { ReactNode } from "react"
import { isPlainObject } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

// Shared presentation helpers for the scheduled_tasks plugin's chat tool
// cards (EPIC-292 / JOB-4222). Lives outside `tool_cards/` on purpose: core's
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
  repositorySlug: string | null
  cadence: string | null
  scheduleTimezone: string | null
  prPileupPolicy: string | null
  enabled: boolean | null
  fireAt: string | null
  nextFireAt: string | null
  lastFiredAt: string | null
  lastSuccessfulFireAt: string | null
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
    (fireAt ? `Once at ${fireAt}` : null)

  return {
    id,
    label,
    state,
    kind: displayValue(value.kind),
    repositorySlug: displayValue(value.repository_slug),
    cadence,
    scheduleTimezone: displayValue(value.schedule_timezone),
    prPileupPolicy: displayValue(value.pr_pileup_policy),
    enabled: typeof value.enabled === "boolean" ? value.enabled : null,
    fireAt,
    nextFireAt: displayValue(value.next_fire_at),
    lastFiredAt: displayValue(value.last_fired_at),
    lastSuccessfulFireAt: displayValue(value.last_successful_fire_at),
    consecutiveFailureCount: numberValue(value.consecutive_failure_count) ?? 0
  }
}

// Parses `{ "scheduled_task": { ...payload, prompt: "..." } }`, the shape
// read_scheduled_task and update_scheduled_task both return.
export function parseScheduledTaskDetail(parsed: unknown): { task: ScheduledTaskCard; prompt: string | null } | null {
  if (!isPlainObject(parsed)) return null

  const task = parseScheduledTask(parsed.scheduled_task)
  if (!task) return null

  const prompt = isPlainObject(parsed.scheduled_task) ? displayValue(parsed.scheduled_task.prompt) : null
  return { task, prompt }
}

export function scheduledTaskHeadline(task: ScheduledTaskCard) {
  return `${task.label} (#${task.id}, ${task.state})`
}

export function FailureBadge({ count }: { count: number }) {
  if (count <= 0) return null

  return (
    <span className="rounded-full bg-amber-100 px-2 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
      {count} consecutive failure{count === 1 ? "" : "s"}
    </span>
  )
}

export function ScheduledTaskSummary({ task }: { task: ScheduledTaskCard }) {
  const nextFire = task.nextFireAt || task.fireAt

  return (
    <>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">#{task.id}</span>
        <StatePill state={task.state} />
        {task.kind ? <Badge>{task.kind.replace(/_/g, " ")}</Badge> : null}
        {task.enabled === false ? <Badge>disabled</Badge> : null}
        <FailureBadge count={task.consecutiveFailureCount} />
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{task.label}</div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {task.cadence ? <Row label="Cadence" value={task.scheduleTimezone ? `${task.cadence} (${task.scheduleTimezone})` : task.cadence} /> : null}
        {task.repositorySlug ? <Row label="Repository" value={task.repositorySlug} /> : null}
        {nextFire ? <Row label="Next fire" value={nextFire} /> : null}
        {task.lastFiredAt ? <Row label="Last fired" value={task.lastFiredAt} /> : null}
        {task.lastSuccessfulFireAt ? <Row label="Last success" value={task.lastSuccessfulFireAt} /> : null}
        {task.prPileupPolicy ? <Row label="PR pileup" value={task.prPileupPolicy} /> : null}
      </dl>
    </>
  )
}

// Small `<details>` disclosure for the long prompt text read/update return.
// Deliberately a local copy of core's explain_stuck_job pattern — that one
// is a private component, not shared API.
export function PromptDisclosure({ prompt }: { prompt: string }) {
  return (
    <details className="rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">
        Prompt
      </summary>
      <div className="mt-1 whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300">{prompt}</div>
    </details>
  )
}

// pause/resume/delete all answer with the same tiny
// `{ scheduled_task_id, label, ... }` acknowledgement shape.
export type ScheduledTaskOutcome = { id: string; label: string }

export function parseScheduledTaskOutcome(parsed: unknown): ScheduledTaskOutcome | null {
  if (!isPlainObject(parsed)) return null

  const id = displayValue(parsed.scheduled_task_id)
  const label = displayValue(parsed.label)
  if (!id || !label) return null

  return { id, label }
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
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">#{outcome.id}</span>
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{outcome.label}</div>
      {detail ? <div className="text-gray-600 dark:text-gray-300">{detail}</div> : null}
    </CardShell>
  )
}
