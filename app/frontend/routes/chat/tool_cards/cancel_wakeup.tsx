import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue } from "../toolCardUi"
import i18n from "@app/i18n"

// Core-owned tool card for cancel_wakeup (the pending-action tool-card work).
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
  return i18n.t("chat:tool_card_wakeup_cancelled", { id: result.wakeupId })
}

function renderExpanded(context: ToolCardContext) {
  const result = parseCancelWakeup(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="text-gray-700 dark:text-gray-300">
        {i18n.t("chat:tool_card_wakeup_cancelled_label")} <span className="font-mono font-medium">#{result.wakeupId}</span>
      </div>
    </CardShell>
  )
}

const cancelWakeupToolCard: ToolCardRenderer = {
  toolName: "cancel_wakeup",
  collapsedSummary,
  renderExpanded
}

export default cancelWakeupToolCard
