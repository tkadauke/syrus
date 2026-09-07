import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

// Plugin-owned tool card for fire_scheduled_task_now (EPIC-292 / JOB-4222).
// The tool returns the standard pending-action shape
// `{ pending_confirmation_id, pending_action_id, state, message }`, but the
// parser is intentionally self-contained here: reaching into core's
// pending-action card module would couple this plugin to another family's
// private helper.
//
// Purely informational — confirm/reject lives on the separately anchored
// PendingActionCard.
type FireNowCard = {
  actionId: string
  state: string
  message: string | null
}

function parseFireNow(context: ToolCardContext): FireNowCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const actionId = displayValue(parsed.pending_action_id) || displayValue(parsed.pending_confirmation_id)
  const state = displayValue(parsed.state)
  if (!actionId || !state) return null

  return { actionId, state, message: displayValue(parsed.message) }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseFireNow(context)
  if (!card) return null

  return `Fire now requested (#${card.actionId}, ${card.state})`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseFireNow(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={card.state} />
        <span className="text-sm font-medium text-gray-900 dark:text-gray-100">Immediate fire requested</span>
      </div>
      {card.message ? <div className="text-gray-700 dark:text-gray-300">{card.message}</div> : null}
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Pending action" value={`#${card.actionId}`} />
      </dl>
      <div className="text-gray-500 dark:text-gray-400">The task does not fire until the operator confirms.</div>
    </CardShell>
  )
}

const fireScheduledTaskNowToolCard: ToolCardRenderer = {
  toolName: "fire_scheduled_task_now",
  collapsedSummary,
  renderExpanded
}

export default fireScheduledTaskNowToolCard
