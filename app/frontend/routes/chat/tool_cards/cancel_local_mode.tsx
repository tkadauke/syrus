import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { LocalModeJobOutcomeCard, LocalModeJobOutcomeEmptyCard, localModeJobIdFromInput, localModeJobOutcomeSummary, parseLocalModeJobOutcome } from "../localModeJobOutcomeCard"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

const failureConfig: ToolFailureConfig = {
  title: "Cancel Local Mode",
  attempted: (context) => {
    const jobId = localModeJobIdFromInput(context)
    return jobId ? `Cancel Local Mode for JOB-${jobId}` : "Cancel Local Mode"
  },
  retrySafety: "caution",
  recovery: "Check the Job state before retrying; cancellation may already have completed."
}

// Local Mode tool card for cancel_local_mode (the tool-card work). See
// open_in_local_mode.tsx for the shared family this belongs to.
function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const result = parseLocalModeJobOutcome(context.parsedResult)
  if (result) return localModeJobOutcomeSummary(result)
  const jobId = localModeJobIdFromInput(context)
  return jobId ? `No outcome returned for JOB-${jobId}` : "No job outcome returned"
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseLocalModeJobOutcome(context.parsedResult)
  const requestedJobId = localModeJobIdFromInput(context)
  return result ? <LocalModeJobOutcomeCard requestedJobId={requestedJobId} result={result} stateTransition /> : <LocalModeJobOutcomeEmptyCard requestedJobId={requestedJobId} />
}

const cancelLocalModeToolCard: ToolCardRenderer = {
  toolName: "cancel_local_mode",
  collapsedSummary,
  renderExpanded
}

export default cancelLocalModeToolCard

export const examples: ToolCardExample[] = [
  {
    id: "returned_to_implemented",
    label: "Returned to implemented",
    input: { job_id: 4225 },
    parsedResult: { job_id: 4225, job_state: "implemented", message: "Local Mode was cancelled for `JOB-4225`." }
  },
  {
    id: "returned_to_closed",
    label: "Returned to closed",
    input: { job_id: 4226 },
    parsedResult: { job_id: 4226, job_state: "closed", message: "The closed Job remains **closed**." }
  },
  {
    id: "failure",
    label: "Cancellation failed",
    input: { job_id: 4227 },
    resultBody: "Error: JOB-4227 is not in Local Mode.",
    resultError: true
  },
  {
    id: "empty",
    label: "Empty response",
    input: { job_id: 4228 }
  }
]
