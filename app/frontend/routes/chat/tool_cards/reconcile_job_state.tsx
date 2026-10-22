import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { displayValue, EntityReference, Row } from "../toolCardUi"

function requestedJobIds(context: ToolCardContext) {
  const ids = Array.isArray(context.input?.job_ids) ? context.input.job_ids : context.input?.job_id == null ? [] : [context.input.job_id]
  return ids.flatMap((id) => {
    const value = displayValue(id)
    return value ? [value] : []
  })
}

function ReconcileJobStateDetails({ context }: { context: ToolCardContext }) {
  const jobIds = requestedJobIds(context)
  const mode = displayValue(context.input?.mode)
  const reason = displayValue(context.input?.reason)

  return (
    <div className="space-y-2">
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <Row label="Mode" value={mode ? <span className="break-all font-mono">{mode}</span> : "Not provided"} />
        <Row
          label={jobIds.length === 1 ? "Job" : "Jobs"}
          value={
            jobIds.length ? (
              <div className="flex min-w-0 flex-wrap gap-x-2 gap-y-1">
                {jobIds.map((jobId) => (
                  <EntityReference id={jobId} key={jobId} kind="job" />
                ))}
              </div>
            ) : (
              "Not provided"
            )
          }
        />
      </dl>
      {reason ? <MarkdownPreview maxLines={4} modalLabel="Reconciliation reason" text={reason} title="Reason" /> : <Row label="Reason" value="Not provided" />}
    </div>
  )
}

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? <PendingActionResultCard details={<ReconcileJobStateDetails context={context} />} omitJob omitReason result={result} /> : null
}

const reconcileJobStateToolCard: ToolCardRenderer = {
  toolName: "reconcile_job_state",
  collapsedSummary,
  renderExpanded
}

export default reconcileJobStateToolCard

export const examples: ToolCardExample[] = [
  {
    id: "single_pending",
    label: "Single pending reconciliation",
    description: "Shows the requested mode, linked Job, and Markdown audit reason before confirmation.",
    input: { job_id: 4222, mode: "mark_failed", reason: "Repair the **stale state** after reviewing the failed workflow." },
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      message: "Reconcile JOB-4222 using mode mark_failed?"
    }
  },
  {
    id: "bulk_pending",
    label: "Bulk automatic reconciliation",
    description: "A long list of linked Jobs wraps responsively while retaining the shared mode and reason.",
    input: {
      job_ids: [41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52],
      mode: "auto",
      reason: "These Jobs share the same **reconciler drift**."
    },
    parsedResult: {
      pending_action_group_id: 88,
      pending_action_id: 502,
      state: "pending",
      member_count: 12,
      message: "Reconcile 12 Jobs using mode auto?"
    }
  },
  {
    id: "validation_error",
    label: "Validation error retains request",
    input: { job_id: 4222, mode: "auto", reason: "Retry after **checking ownership**." },
    parsedResult: { error: "invalid_request", message: "The requested reconciliation is not eligible." },
    resultError: true
  },
  {
    id: "missing_input",
    label: "Missing request input",
    description: "Labels unavailable mode, Job, and reason fields instead of inferring them from the message.",
    parsedResult: { pending_action_id: 503, state: "pending", message: "Reconcile JOB-4222 using mode auto?" }
  }
]
