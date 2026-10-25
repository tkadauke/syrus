import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { displayValue, Row } from "../toolCardUi"
import i18n from "@app/i18n"

// Core-owned tool card for force_state_transition. Reuses the shared
// pending-action parsing/rendering (which already surfaces the admin audit
// reason and target context) and adds the requested AASM event read back
// from the tool call's own input arguments.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  if (!result) return null

  const input = isPlainObject(context.input) ? context.input : {}
  const event = displayValue(input.event)

  return <PendingActionResultCard details={event ? <Row label={i18n.t("chat:mutation_requested_event")} value={event} /> : null} result={result} />
}

const forceStateTransitionToolCard: ToolCardRenderer = {
  toolName: "force_state_transition",
  collapsedSummary,
  renderExpanded
}

export default forceStateTransitionToolCard
