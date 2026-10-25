import i18n from "../../../i18n"
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
        <Row
          label={i18n.t("chat:ops_mode_a7b93d")}
          value={mode ? <span className="break-all font-mono">{mode}</span> : i18n.t("chat:ops_not_provided_20a041")}
        />
        <Row
          label={jobIds.length === 1 ? i18n.t("chat:ops_job_30c8cb") : i18n.t("chat:ops_jobs_437736")}
          value={
            jobIds.length ? (
              <div className="flex min-w-0 flex-wrap gap-x-2 gap-y-1">
                {jobIds.map((jobId) => (
                  <EntityReference id={jobId} key={jobId} kind="job" />
                ))}
              </div>
            ) : (
              i18n.t("chat:ops_not_provided_20a041")
            )
          }
        />
      </dl>
      {reason ? (
        <MarkdownPreview maxLines={4} modalLabel={i18n.t("chat:ops_reconciliation_reason_feaf5e")} text={reason} title={i18n.t("chat:ops_reason_f219cc")} />
      ) : (
        <Row label={i18n.t("chat:ops_reason_f219cc")} value={i18n.t("chat:ops_not_provided_20a041")} />
      )}
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
    label: i18n.t("chat:ops_single_pending_reconciliation_25eb1e"),
    description: i18n.t("chat:ops_shows_the_requested_mode_linked_job_and_markdown_71ba5e"),
    input: { job_id: 4222, mode: "mark_failed", reason: i18n.t("chat:ops_repair_the_stale_state_after_reviewing_the_failed_workfl_29f3de") },
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      message: "Reconcile JOB-4222 using mode mark_failed?"
    }
  },
  {
    id: "bulk_pending",
    label: i18n.t("chat:ops_bulk_automatic_reconciliation_f6809a"),
    description: i18n.t("chat:ops_a_long_list_of_linked_jobs_wraps_responsively_wh_cc5393"),
    input: {
      job_ids: [41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52],
      mode: "auto",
      reason: i18n.t("chat:ops_these_jobs_share_the_same_reconciler_drift_2c7e1f")
    },
    parsedResult: {
      pending_action_group_id: 88,
      pending_action_id: 502,
      state: "pending",
      member_count: 12,
      message: i18n.t("chat:ops_reconcile_12_jobs_using_mode_auto_ecc22d")
    }
  },
  {
    id: "validation_error",
    label: i18n.t("chat:ops_validation_error_retains_request_878fbe"),
    input: { job_id: 4222, mode: "auto", reason: i18n.t("chat:ops_retry_after_checking_ownership_2d2854") },
    parsedResult: { error: "invalid_request", message: i18n.t("chat:ops_the_requested_reconciliation_is_not_eligible_892893") },
    resultError: true
  },
  {
    id: "missing_input",
    label: i18n.t("chat:ops_missing_request_input_13053c"),
    description: i18n.t("chat:ops_labels_unavailable_mode_job_and_reason_fields_in_4693d2"),
    parsedResult: { pending_action_id: 503, state: "pending", message: i18n.t("chat:ops_reconcile_job_4222_using_mode_auto_ef460b") }
  }
]
