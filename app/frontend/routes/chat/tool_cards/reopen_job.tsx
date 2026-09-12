import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { jobEpicMaintenanceCollapsedSummary, jobEpicMaintenanceExpandedBody } from "../jobEpicMaintenanceToolCard"
import { countFromInputArray, stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, type ToolFailureConfig } from "../toolFailureSummaryCard"

const failureConfig: ToolFailureConfig = {
  title: "Job reopen",
  attempted: (context) => {
    const jobId = stringFromInput(context, ["job_id"])
    const count = countFromInputArray(context, "job_ids")
    if (jobId) return `Reopen JOB-${jobId}`
    if (count != null) return `Reopen ${count} Job${count === 1 ? "" : "s"}`
    return "Reopen Job"
  },
  retrySafety: "caution",
  recovery: "Check whether a reopen confirmation is already pending before retrying."
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  return jobEpicMaintenanceCollapsedSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  return jobEpicMaintenanceExpandedBody(context)
}

const reopenJobToolCard: ToolCardRenderer = {
  toolName: "reopen_job",
  collapsedSummary,
  renderExpanded
}

export default reopenJobToolCard
