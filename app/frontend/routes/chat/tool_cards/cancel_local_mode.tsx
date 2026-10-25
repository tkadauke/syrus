import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { LocalModeJobOutcomeToolCard, localModeJobOutcomeModel, localModeJobOutcomeSummary } from "../localModeJobOutcomeCard"
import i18n from "@app/i18n"

// Local Mode tool card for cancel_local_mode (the tool-card work). See
// open_in_local_mode.tsx for the shared family this belongs to.
function collapsedSummary(context: ToolCardContext) {
  const model = localModeJobOutcomeModel(context)
  if (model.error) return i18n.t("chat:mutation_local_mode_cancellation_failed")
  return model.result ? localModeJobOutcomeSummary(model.result) : i18n.t("chat:shared.no_job_outcome")
}

function renderExpanded(context: ToolCardContext) {
  return <LocalModeJobOutcomeToolCard context={context} />
}

export const examples: ToolCardExample[] = [
  {
    id: "returned_to_implemented",
    label: i18n.t("chat:mutation_example_returned_implemented"),
    input: { job_id: 42 },
    parsedResult: { job_id: 42, job_state: "implemented", message: "JOB-42 returned to `implemented`." }
  },
  {
    id: "closed",
    label: i18n.t("chat:mutation_example_closed_after_cancellation"),
    input: { job_id: 43 },
    parsedResult: { job_id: 43, job_state: "closed", message: "JOB-43 was `closed`." }
  },
  {
    id: "error",
    label: i18n.t("chat:mutation_example_cancellation_failed"),
    input: { job_id: 44 },
    resultBody: "Unable to cancel Local Mode",
    resultError: true
  },
  { id: "empty", label: i18n.t("chat:mutation_example_empty_result"), input: { job_id: 45 }, parsedResult: {} }
]

const cancelLocalModeToolCard: ToolCardRenderer = {
  toolName: "cancel_local_mode",
  collapsedSummary,
  renderExpanded
}

export default cancelLocalModeToolCard
