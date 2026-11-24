import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"
import { displayValue, EmptyState, EntityReference, Row } from "../toolCardUi"

const failureConfig: ToolFailureConfig = {
  title: i18n.t("chat:hold_job.failure_title"),
  attempted: () => i18n.t("chat:hold_job.attempted"),
  retrySafety: "caution",
  recovery: i18n.t("chat:hold_job.recovery")
}

// Target and effect shown on the confirmation card: which Job is held and what
// the hold does (and does not do).
function InputDetails({ context, showJob = true }: { context: ToolCardContext; showJob?: boolean }) {
  if (!context.input) return <EmptyState>{i18n.t("chat:hold_job.input_unavailable")}</EmptyState>

  const jobId = displayValue(context.input.job_id)
  const toBacklog = context.input.to_backlog === true

  return (
    <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
      {showJob ? (
        <Row
          label={i18n.t("chat:hold_job.job")}
          value={jobId ? <EntityReference id={jobId} kind="job" /> : i18n.t("chat:hold_job.not_provided")}
        />
      ) : null}
      <Row label={i18n.t("chat:hold_job.effect")} value={i18n.t(toBacklog ? "chat:hold_job.effect_backlog" : "chat:hold_job.effect_waiting")} />
      <Row label={i18n.t("chat:hold_job.kept")} value={i18n.t("chat:hold_job.kept_value")} />
    </dl>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context))
    return (
      <ToolFailureSummaryCard config={failureConfig} context={context}>
        <InputDetails context={context} />
      </ToolFailureSummaryCard>
    )

  const result = parsePendingActionResult(context)
  if (!result) return null

  const resultJobId = result.kind === "dry_run_evidence" ? result.evidence?.jobId || result.context.jobId : result.jobId
  return <PendingActionResultCard details={<InputDetails context={context} showJob={!resultJobId} />} result={result} />
}

const holdJobToolCard: ToolCardRenderer = {
  toolName: "hold_job",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export default holdJobToolCard

export const examples: ToolCardExample[] = [
  {
    id: "pending_hold",
    label: i18n.t("chat:hold_job.example_pending"),
    input: { job_id: 42, reason: "JOB-42 is running before JOB-41 has an open PR." },
    parsedResult: { pending_action_id: 501, state: "pending", reason: "JOB-42 is running before JOB-41 has an open PR.", message: "Hold JOB-42?" }
  },
  {
    id: "refused",
    label: i18n.t("chat:hold_job.example_error"),
    input: { job_id: 42, reason: "Run is out of turn." },
    resultBody: "Error: All dependencies of JOB-42 are satisfied, so there is nothing to wait for.",
    resultError: true
  }
]
