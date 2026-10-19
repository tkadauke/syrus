import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { SpendingCard, spendingCost, spendingResult, spendingWindow } from "../spendingToolCard"

function collapsedSummary(context: ToolCardContext) {
  const result = spendingResult(context)
  const window = spendingWindow(context)
  const cost = result && spendingCost(result.cost)
  return cost && window ? `${cost} over ${window}` : null
}

const getSpendingToolCard: ToolCardRenderer = {
  toolName: "get_spending",
  collapsedSummary,
  renderExpanded: (context) => {
    if (!context.resultError && spendingWindow(context) && !spendingResult(context)) return null
    return <SpendingCard context={context} />
  }
}

export default getSpendingToolCard
