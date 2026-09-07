import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row } from "../toolCardUi"

// Core-owned tool card for schedule_wakeup (EPIC-292 / JOB-4222).
type ScheduleWakeupResult = { wakeupId: string; fireAt: string }

function parseScheduleWakeup(context: ToolCardContext): ScheduleWakeupResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const wakeupId = displayValue(parsed.wakeup_id)
  const fireAt = displayValue(parsed.fire_at)
  if (!wakeupId || !fireAt) return null
  return { wakeupId, fireAt }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseScheduleWakeup(context)
  if (!result) return null
  return `Wakeup scheduled for ${result.fireAt}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseScheduleWakeup(context)
  if (!result) return null

  return (
    <CardShell>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Wakeup" value={`#${result.wakeupId}`} />
        <Row label="Fires at" value={result.fireAt} />
      </dl>
    </CardShell>
  )
}

const scheduleWakeupToolCard: ToolCardRenderer = {
  toolName: "schedule_wakeup",
  collapsedSummary,
  renderExpanded
}

export default scheduleWakeupToolCard
