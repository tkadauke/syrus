import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue } from "../toolCardUi"

// Core-owned tool card for cancel_wakeup (EPIC-292 / JOB-4222).
type CancelWakeupResult = { wakeupId: string; cancelled: boolean }

function parseCancelWakeup(context: ToolCardContext): CancelWakeupResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const wakeupId = displayValue(parsed.wakeup_id)
  if (!wakeupId || parsed.cancelled !== true) return null
  return { wakeupId, cancelled: true }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseCancelWakeup(context)
  if (!result) return null
  return `Cancelled wakeup #${result.wakeupId}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseCancelWakeup(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="text-gray-700 dark:text-gray-300">Cancelled wakeup <span className="font-mono font-medium">#{result.wakeupId}</span></div>
    </CardShell>
  )
}

const cancelWakeupToolCard: ToolCardRenderer = {
  toolName: "cancel_wakeup",
  collapsedSummary,
  renderExpanded
}

export default cancelWakeupToolCard
