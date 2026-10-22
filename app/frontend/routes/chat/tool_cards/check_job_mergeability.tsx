import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { displayValue, EntityReference, Row } from "../toolCardUi"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  if (!result) return null

  const jobId = displayValue(context.input?.job_id)
  const job = jobId ? <EntityReference id={jobId} kind="job" /> : i18n.t("chat:check_job_mergeability.not_provided")

  return (
    <PendingActionResultCard
      detailTitle={i18n.t("chat:check_job_mergeability.outcome")}
      details={
        <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
          <Row label={i18n.t("chat:check_job_mergeability.job")} value={job} />
        </dl>
      }
      omitJob
      result={result}
    />
  )
}

const checkJobMergeabilityToolCard: ToolCardRenderer = {
  toolName: "check_job_mergeability",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export default checkJobMergeabilityToolCard
