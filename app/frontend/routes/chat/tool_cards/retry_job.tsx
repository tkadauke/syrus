import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { displayValue, EmptyState, EntityReference, Row } from "../toolCardUi"

function requestedJobIds(context: ToolCardContext) {
  const values = Array.isArray(context.input?.job_ids) ? context.input.job_ids : context.input?.job_id == null ? [] : [context.input.job_id]
  return values.flatMap((value) => {
    const id = displayValue(value)
    return id ? [id] : []
  })
}

function retryWorkflows(context: ToolCardContext) {
  const outcome = context.livePendingAction?.outcome
  if (!outcome || !Array.isArray(outcome.workflows)) return []
  return outcome.workflows.flatMap((value) => {
    if (!value || typeof value !== "object" || Array.isArray(value)) return []
    const record = value as Record<string, unknown>
    const workflowId = displayValue(record.workflow_id)
    if (!workflowId) return []
    return [{ workflowId, jobId: displayValue(record.job_id) }]
  })
}

function RetryJobDetails({ context }: { context: ToolCardContext }) {
  const jobIds = requestedJobIds(context)
  const workflows = retryWorkflows(context)
  return (
    <>
      <Row
        label={jobIds.length === 1 ? i18n.t("chat:retry_job.job") : i18n.t("chat:retry_job.jobs")}
        value={
          jobIds.length ? (
            <div className="flex min-w-0 flex-wrap gap-x-2 gap-y-1">
              {jobIds.map((jobId) => (
                <EntityReference id={jobId} key={jobId} kind="job" />
              ))}
            </div>
          ) : (
            <EmptyState>{i18n.t("chat:retry_job.missing_target")}</EmptyState>
          )
        }
      />
      {workflows.length ? (
        <Row
          label={i18n.t("chat:retry_job.started_workflows")}
          value={
            <div className="flex min-w-0 flex-wrap gap-x-2 gap-y-1">
              {workflows.map(({ workflowId, jobId }) => (
                <EntityReference id={workflowId} jobId={jobId} key={`${jobId}-${workflowId}`} kind="workflow" touchTarget wrap="break" />
              ))}
            </div>
          }
        />
      ) : null}
    </>
  )
}

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? <PendingActionResultCard details={<RetryJobDetails context={context} />} omitJob result={result} /> : null
}

const retryJobToolCard: ToolCardRenderer = {
  toolName: "retry_job",
  collapsedSummary,
  renderExpanded
}

export default retryJobToolCard

const pendingResult = {
  pending_confirmation_id: 501,
  pending_action_id: 501,
  state: "pending",
  message: "Job retry requires operator confirmation."
}

export const examples: ToolCardExample[] = [
  { id: "single_pending", label: "Single retry pending", input: { job_id: 4222 }, parsedResult: pendingResult },
  {
    id: "bulk_pending",
    label: "Bulk retry pending",
    input: { job_ids: [4222, 4223] },
    parsedResult: { ...pendingResult, pending_action_group_id: 88, member_count: 2, message: "Retry 2 Jobs?" }
  },
  {
    id: "retry_started",
    label: "Retry workflow started",
    input: { job_id: 4222 },
    parsedResult: pendingResult,
    livePendingAction: {
      id: 501,
      action: "retry_job",
      state: "confirmed",
      label: "Retry JOB-4222",
      detail: null,
      execution_status: "applied",
      execution_step: "Applied.",
      outcome: { workflows: [{ workflow_id: 61270, job_id: 4222 }] },
      app_confirm_path: "/api/v1/app/chats/7/pending_actions/501/confirm",
      app_reject_path: "/api/v1/app/chats/7/pending_actions/501/reject"
    }
  },
  { id: "ineligible", label: "Retry ineligible", input: { job_id: 4222 }, resultBody: "Error: Job is not eligible for retry.", resultError: true },
  { id: "missing_input", label: "Missing Job input", parsedResult: pendingResult }
]
