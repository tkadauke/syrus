import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { LocalModeJobOutcomeToolCard, localModeJobOutcomeModel, localModeJobOutcomeSummary } from "../localModeJobOutcomeCard"

// Local Mode tool card for cancel_local_mode (the tool-card work). See
// open_in_local_mode.tsx for the shared family this belongs to.
function collapsedSummary(context: ToolCardContext) {
  const model = localModeJobOutcomeModel(context)
  if (model.error) return "Local Mode cancellation failed"
  return model.result ? localModeJobOutcomeSummary(model.result) : "No job outcome returned"
}

function renderExpanded(context: ToolCardContext) {
  return <LocalModeJobOutcomeToolCard context={context} />
}

export const examples: ToolCardExample[] = [
  {
    id: "returned_to_implemented",
    label: "Returned to implemented",
    input: { job_id: 42 },
    parsedResult: { job_id: 42, job_state: "implemented", message: "JOB-42 returned to `implemented`." }
  },
  {
    id: "closed",
    label: "Closed after cancellation",
    input: { job_id: 43 },
    parsedResult: { job_id: 43, job_state: "closed", message: "JOB-43 was `closed`." }
  },
  { id: "error", label: "Cancellation failed", input: { job_id: 44 }, resultBody: "Unable to cancel Local Mode", resultError: true },
  { id: "empty", label: "Empty result", input: { job_id: 45 }, parsedResult: {} }
]

const cancelLocalModeToolCard: ToolCardRenderer = {
  toolName: "cancel_local_mode",
  collapsedSummary,
  renderExpanded
}

export default cancelLocalModeToolCard
