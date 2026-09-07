import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

// Plugin-owned tool card for schedule_recurring (EPIC-292 / JOB-4222).
//
// This tool's success payload is deliberately narrow and does NOT match the
// standard pending-action shape used elsewhere: it carries only
// `{ pending_confirmation_id, schedule_explanation, next_fire_at }` with no
// `pending_action_id`, `state`, or `message`. Hence a bespoke parser rather
// than reuse of the pending-action family's.
//
// Purely informational: the interactive confirm/reject affordance is the
// separately anchored PendingActionCard, not this tool-result card.
type ScheduleRecurringCard = {
  confirmationId: string
  explanation: string | null
  nextFireAt: string | null
}

function parseScheduleRecurring(context: ToolCardContext): ScheduleRecurringCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const confirmationId = displayValue(parsed.pending_confirmation_id)
  if (!confirmationId) return null

  const explanation = displayValue(parsed.schedule_explanation)
  const nextFireAt = displayValue(parsed.next_fire_at)
  // A well-formed proposal always describes its cadence one way or the
  // other; neither present means this isn't the payload we think it is.
  if (!explanation && !nextFireAt) return null

  return { confirmationId, explanation, nextFireAt }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseScheduleRecurring(context)
  if (!card) return null

  return card.explanation
    ? `Recurring task proposed: ${card.explanation}`
    : `Recurring task proposed (confirmation #${card.confirmationId})`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseScheduleRecurring(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="proposed" />
        <span className="text-sm font-medium text-gray-900 dark:text-gray-100">Recurring task proposed</span>
      </div>
      {card.explanation ? <div className="text-gray-700 dark:text-gray-300">{card.explanation}</div> : null}
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Pending confirmation" value={`#${card.confirmationId}`} />
        {card.nextFireAt ? <Row label="First fire" value={card.nextFireAt} /> : null}
      </dl>
      <div className="text-gray-500 dark:text-gray-400">Not created yet — awaiting operator confirmation.</div>
    </CardShell>
  )
}

const scheduleRecurringToolCard: ToolCardRenderer = {
  toolName: "schedule_recurring",
  collapsedSummary,
  renderExpanded
}

export default scheduleRecurringToolCard
