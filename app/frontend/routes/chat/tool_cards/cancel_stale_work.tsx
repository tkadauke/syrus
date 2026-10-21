import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"
import { displayValue, EmptyState, EntityReference, Row } from "../toolCardUi"

const failureConfig: ToolFailureConfig = {
  title: i18n.t("chat:cancel_stale_work.failure_title"),
  attempted: () => i18n.t("chat:cancel_stale_work.attempted"),
  retrySafety: "caution",
  recovery: i18n.t("chat:cancel_stale_work.recovery")
}

function idList(value: unknown) {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    const id = displayValue(entry)
    return id ? [id] : []
  })
}

function LinkedIds({ context, ids, kind }: { context: ToolCardContext; ids: string[]; kind: "workflow" | "run" }) {
  const jobId = displayValue(context.input?.job_id)
  if (ids.length === 0) return <span className="text-text-subtle">{i18n.t("chat:cancel_stale_work.none")}</span>

  return (
    <span className="flex min-w-0 flex-wrap gap-x-3 gap-y-1">
      {ids.map((id) => (
        <EntityReference href={kind === "run" ? `/admin/runs/${id}` : undefined} id={id} jobId={jobId} key={id} kind={kind} />
      ))}
    </span>
  )
}

function InputDetails({ context, showJob = true }: { context: ToolCardContext; showJob?: boolean }) {
  if (!context.input) return <EmptyState>{i18n.t("chat:cancel_stale_work.input_unavailable")}</EmptyState>

  const jobId = displayValue(context.input.job_id)
  const reconcile = context.input.reconcile
  const reconcileLabel =
    typeof reconcile === "boolean"
      ? i18n.t(reconcile ? "chat:cancel_stale_work.yes" : "chat:cancel_stale_work.no")
      : i18n.t("chat:cancel_stale_work.default_yes")

  return (
    <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
      {showJob ? (
        <Row
          label={i18n.t("chat:cancel_stale_work.job")}
          value={jobId ? <EntityReference id={jobId} kind="job" /> : i18n.t("chat:cancel_stale_work.not_provided")}
        />
      ) : null}
      <Row label={i18n.t("chat:cancel_stale_work.reconcile")} value={reconcileLabel} />
      <Row
        label={i18n.t("chat:cancel_stale_work.workflows")}
        value={<LinkedIds context={context} ids={idList(context.input.workflow_ids)} kind="workflow" />}
      />
      <Row label={i18n.t("chat:cancel_stale_work.runs")} value={<LinkedIds context={context} ids={idList(context.input.run_ids)} kind="run" />} />
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

const cancelStaleWorkToolCard: ToolCardRenderer = {
  toolName: "cancel_stale_work",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export default cancelStaleWorkToolCard

export const examples: ToolCardExample[] = [
  {
    id: "pending_targets",
    label: i18n.t("chat:cancel_stale_work.example_pending"),
    input: { job_id: 42, workflow_ids: [101, 102], run_ids: [201, 202], reconcile: true, reason: "These attempts are stale." },
    parsedResult: { pending_action_id: 501, state: "pending", reason: "These attempts are stale.", message: "Cancel stale work for JOB-42?" }
  },
  {
    id: "ineligible",
    label: i18n.t("chat:cancel_stale_work.example_error"),
    input: { job_id: 42, workflow_ids: [], run_ids: [], reconcile: false, reason: "Cancel stale work." },
    resultBody: "Error: no stale work is eligible for cancellation",
    resultError: true
  }
]
