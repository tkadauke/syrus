import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { displayValue, EmptyState, EntityReference, Row } from "../toolCardUi"
import i18n from "@app/i18n"

function requestedJobIds(context: ToolCardContext) {
  const ids = Array.isArray(context.input?.job_ids) ? context.input.job_ids : context.input?.job_id == null ? [] : [context.input.job_id]
  return ids.flatMap((id) => {
    const value = displayValue(id)
    return value ? [value] : []
  })
}

function ForceLandingRecheckDetails({ context, showReason }: { context: ToolCardContext; showReason: boolean }) {
  const jobIds = requestedJobIds(context)
  return (
    <>
      <Row
        label={i18n.t("chat:force_landing_recheck.jobs", { count: jobIds.length })}
        value={
          jobIds.length ? (
            <div className="flex min-w-0 flex-wrap gap-x-2 gap-y-1">
              {jobIds.map((jobId) => (
                <EntityReference id={jobId} key={jobId} kind="job" />
              ))}
            </div>
          ) : (
            <EmptyState>{i18n.t("chat:force_landing_recheck.not_provided")}</EmptyState>
          )
        }
      />
      {showReason && displayValue(context.input?.reason) ? (
        <MarkdownPreview
          maxLines={4}
          modalLabel={i18n.t("chat:force_landing_recheck.pending_reason")}
          text={displayValue(context.input?.reason)}
          title={i18n.t("chat:force_landing_recheck.reason")}
        />
      ) : null}
    </>
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
  return result ? (
    <PendingActionResultCard
      detailTitle={i18n.t("chat:force_landing_recheck.outcome")}
      details={<ForceLandingRecheckDetails context={context} showReason={result.kind === "error"} />}
      omitJob
      result={result}
    />
  ) : null
}

const forceLandingRecheckToolCard: ToolCardRenderer = {
  toolName: "force_landing_recheck",
  collapsedSummary,
  renderExpanded
}

export default forceLandingRecheckToolCard

const bulkJobIds = [41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52]

export const examples: ToolCardExample[] = [
  {
    id: "bulk_pending",
    label: i18n.t("chat:force_landing_recheck.example_bulk_pending"),
    description: i18n.t("chat:force_landing_recheck.example_bulk_pending_description"),
    input: { job_ids: bulkJobIds, reason: "**Recheck** landing metadata after the dependency graph changed." },
    parsedResult: {
      pending_action_group_id: 88,
      pending_action_id: 501,
      state: "pending",
      member_count: bulkJobIds.length,
      message: `Force landing recheck for ${bulkJobIds.length} Jobs?`
    },
    livePendingAction: {
      id: 501,
      action: "force_landing_recheck",
      state: "pending",
      label: "Force landing recheck",
      detail:
        "- JOB-41 — observed state: approved; observed blocker: dependencies\n- JOB-42 — observed state: landing; observed blocker: none\n- JOB-43 — observed state: implemented; observed blocker: checks_pending",
      reason: "**Recheck** landing metadata after the dependency graph changed.",
      app_confirm_path: "/api/v1/app/chats/7/pending_actions/501/confirm",
      app_reject_path: "/api/v1/app/chats/7/pending_actions/501/reject"
    }
  },
  {
    id: "bulk_confirmed",
    label: i18n.t("chat:force_landing_recheck.example_bulk_confirmed"),
    input: { job_ids: [41, 42, 43], reason: "Refresh stale landing metadata." },
    parsedResult: {
      pending_action_group_id: 88,
      pending_action_id: 501,
      state: "pending",
      member_count: 3,
      message: "Force landing recheck for 3 Jobs?"
    },
    livePendingAction: {
      id: 501,
      action: "force_landing_recheck",
      state: "confirmed",
      label: "Force landing recheck",
      detail:
        "- JOB-41 — observed state: approved; observed blocker: dependencies; refreshed state: landing; refreshed blocker: none\n- JOB-42 — observed state: landing; observed blocker: none; refreshed state: closed; refreshed blocker: none\n- JOB-43 — observed state: implemented; observed blocker: checks_pending; refreshed state: approved; refreshed blocker: mergeability_unknown",
      execution_status: "applied",
      execution_step: "Applied.",
      reason: "Refresh stale landing metadata.",
      app_confirm_path: "/api/v1/app/chats/7/pending_actions/501/confirm",
      app_reject_path: "/api/v1/app/chats/7/pending_actions/501/reject"
    }
  },
  {
    id: "error_with_reason",
    label: i18n.t("chat:force_landing_recheck.example_error"),
    input: { job_ids: [41, 404], reason: "**Retry** after validating the missing Job." },
    parsedResult: { error: "invalid_request", message: "One or more Jobs could not be rechecked." }
  },
  {
    id: "missing_input",
    label: i18n.t("chat:force_landing_recheck.example_missing_input"),
    parsedResult: { pending_action_id: 501, state: "pending", message: "Force landing recheck for JOB-4222?" }
  }
]
