import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { jobEpicMaintenanceCollapsedSummary, jobEpicMaintenanceExpandedBody } from "../jobEpicMaintenanceToolCard"
import {
  countFromInputArray,
  stringFromInput,
  ToolFailureSummaryCard,
  toolFailureCollapsedSummary,
  toolFailureDetected,
  type ToolFailureConfig
} from "../toolFailureSummaryCard"
import i18n from "@app/i18n"

function failureConfig(): ToolFailureConfig {
  return {
    title: i18n.t("chat:mutation_job_reopen"),
    attempted: (context) => {
      const jobId = stringFromInput(context, ["job_id"])
      const count = countFromInputArray(context, "job_ids")
      if (jobId) return i18n.t("chat:mutation_reopen_job_id", { id: jobId })
      if (count != null) return i18n.t("chat:mutation_reopen_jobs", { count })
      return i18n.t("chat:mutation_reopen_job")
    },
    retrySafety: "caution",
    recovery: i18n.t("chat:mutation_reopen_recovery")
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig())
  if (failureSummary) return failureSummary

  return jobEpicMaintenanceCollapsedSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig()} context={context} />

  return jobEpicMaintenanceExpandedBody(context)
}

const reopenJobToolCard: ToolCardRenderer = {
  toolName: "reopen_job",
  collapsedSummary,
  renderExpanded
}

export default reopenJobToolCard
