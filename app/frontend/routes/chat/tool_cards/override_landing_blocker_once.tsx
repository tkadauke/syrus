import i18n from "../../../i18n"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { displayValue, EntityReference, Row } from "../toolCardUi"

function RequestDetails({ context }: { context: ToolCardContext }) {
  const jobId = displayValue(context.input?.job_id)
  const blockerKey = displayValue(context.input?.blocker_key)
  const reason = displayValue(context.input?.reason)

  return (
    <div className="space-y-2">
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <Row label={i18n.t("chat:ops_job_30c8cb")} value={jobId ? <EntityReference id={jobId} kind="job" /> : i18n.t("chat:ops_not_provided_20a041")} />
        <Row
          label={i18n.t("chat:ops_blocker_key_da7f7b")}
          value={blockerKey ? <span className="break-all font-mono">{blockerKey}</span> : i18n.t("chat:ops_not_provided_20a041")}
        />
      </dl>
      {reason ? (
        <MarkdownPreview maxLines={4} modalLabel={i18n.t("chat:ops_audit_reason_7bbb5b")} text={reason} title={i18n.t("chat:ops_audit_reason_7bbb5b")} />
      ) : (
        <Row label={i18n.t("chat:ops_audit_reason_7bbb5b")} value={i18n.t("chat:ops_not_provided_20a041")} />
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
  return result ? <PendingActionResultCard details={<RequestDetails context={context} />} omitBlocker omitJob omitReason result={result} /> : null
}

const overrideLandingBlockerOnceToolCard: ToolCardRenderer = {
  toolName: "override_landing_blocker_once",
  collapsedSummary,
  renderExpanded
}

export default overrideLandingBlockerOnceToolCard

const longBlockerKey = "dependency_blocked_by_an_exceptionally_long_upstream_job_identifier"

export const examples: ToolCardExample[] = [
  {
    id: "pending_override",
    label: i18n.t("chat:ops_pending_blocker_override_73edd9"),
    description: i18n.t("chat:ops_shows_the_linked_job_long_wrapping_blocker_key_a_eb406b"),
    input: {
      job_id: 4222,
      blocker_key: longBlockerKey,
      reason: "**Reviewed** the upstream dependency and approved this one-time override."
    },
    parsedResult: {
      pending_confirmation_id: 501,
      pending_action_id: 501,
      state: "pending",
      message: `Override ${longBlockerKey} once for JOB-4222? Refreshed state is included in the pending action.`
    }
  },
  {
    id: "applied_override",
    label: i18n.t("chat:ops_applied_blocker_override_b1650e"),
    description: i18n.t("chat:ops_shows_the_completed_live_pending_action_state_wh_3972a3"),
    input: {
      job_id: 4222,
      blocker_key: "landing_paused",
      reason: i18n.t("chat:ops_the_queue_pause_was_confirmed_stale_after_manual_review_a34f90")
    },
    parsedResult: {
      pending_confirmation_id: 502,
      pending_action_id: 502,
      state: "pending",
      message: "Override landing_paused once for JOB-4222? Refreshed state is included in the pending action."
    },
    livePendingAction: {
      id: 502,
      action: "override_landing_blocker_once",
      state: "confirmed",
      label: i18n.t("chat:ops_override_landing_blocker_once_819e31"),
      detail: i18n.t("chat:ops_the_one_time_override_was_recorded_and_the_landing_queue_a06bbe"),
      execution_status: "applied",
      execution_step: i18n.t("chat:ops_applied_c0d308"),
      reason: i18n.t("chat:ops_the_queue_pause_was_confirmed_stale_after_manual_review_a34f90"),
      app_confirm_path: "/api/v1/app/chats/7/pending_actions/502/confirm",
      app_reject_path: "/api/v1/app/chats/7/pending_actions/502/reject"
    }
  },
  {
    id: "validation_error",
    label: i18n.t("chat:ops_blocker_changed_validation_error_a26076"),
    description: i18n.t("chat:ops_keeps_the_requested_job_blocker_key_and_audit_re_48261d"),
    input: {
      job_id: 4222,
      blocker_key: "dependencies",
      reason: i18n.t("chat:ops_override_approved_after_manual_review_of_the_dependency__587d52")
    },
    parsedResult: {
      error: "invalid_request",
      message: i18n.t("chat:ops_the_landing_blocker_changed_before_confirmation_faec5c")
    },
    resultError: true
  },
  {
    id: "missing_input",
    label: i18n.t("chat:ops_missing_request_input_13053c"),
    description: i18n.t("chat:ops_exercises_unavailable_labels_for_every_audit_cri_89ba08"),
    parsedResult: {
      pending_confirmation_id: 503,
      pending_action_id: 503,
      state: "pending",
      message: "Override landing_paused once for JOB-4222?"
    }
  }
]
