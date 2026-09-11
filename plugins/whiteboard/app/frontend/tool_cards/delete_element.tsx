import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { ElementActionCard, ElementFailureCard, elementActionSummary, elementFailureSummary, isPlainObject, parseElementResult } from "../whiteboardToolCard"

// Plugin-owned tool card for delete_element (the pending-action tool-card work).
const ACTION = "Deleted element"

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = elementFailureSummary(context, ACTION)
  if (failureSummary) return failureSummary

  const result = parseElementResult(context.parsedResult)
  if (!result) return null

  return elementActionSummary(ACTION, result, isPlainObject(context.input) ? context.input : undefined)
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ElementFailureCard action={ACTION} context={context} />

  const result = parseElementResult(context.parsedResult)
  if (!result) return null

  return <ElementActionCard action={ACTION} input={isPlainObject(context.input) ? context.input : undefined} result={result} />
}

const deleteElementToolCard: ToolCardRenderer = {
  toolName: "delete_element",
  collapsedSummary,
  renderExpanded
}

export default deleteElementToolCard
