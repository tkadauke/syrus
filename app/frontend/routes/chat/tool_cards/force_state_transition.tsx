import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard, type PendingActionInputField } from "../pendingActionToolCard"
import { displayValue, Row, StatePill } from "../toolCardUi"
import i18n from "@app/i18n"

// Core-owned tool card for force_state_transition. Reuses the shared
// pending-action parsing/rendering (which already surfaces the admin audit
// reason and target context) and adds the requested AASM event read back
// from the tool call's own input arguments.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? pendingActionCollapsedSummary(result) : null
}

const inputFields: PendingActionInputField[] = [
  { key: "event", label: () => i18n.t("chat:mutation_requested_event"), format: "badge" },
  { key: "reason", label: () => i18n.t("chat:force_state_transition.reason"), format: "markdown" }
]

function snapshotJobState(snapshot: unknown, jobId: unknown) {
  if (!isPlainObject(snapshot) || !Array.isArray(snapshot.jobs)) return null
  const expectedId = displayValue(jobId)
  const job = snapshot.jobs.find((entry) => isPlainObject(entry) && (!expectedId || displayValue(entry.id) === expectedId))
  return isPlainObject(job) ? displayValue(job.state) : null
}

function TransitionDetails({ context }: { context: ToolCardContext }) {
  const input = isPlainObject(context.input) ? context.input : {}
  const live = context.livePendingAction
  const fromState = snapshotJobState(live?.before_snapshot, input.job_id)
  const toState = snapshotJobState(live?.after_snapshot, input.job_id)

  if (fromState && toState) {
    return (
      <Row
        label={i18n.t("chat:force_state_transition.transition")}
        value={
          <span className="inline-flex flex-wrap items-center gap-1.5">
            <StatePill state={fromState} />
            <span aria-hidden="true" className="text-text-muted">
              →
            </span>
            <StatePill state={toState} />
          </span>
        }
      />
    )
  }

  return null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  if (!result) return null

  const input = isPlainObject(context.input) ? context.input : {}
  return <PendingActionResultCard details={<TransitionDetails context={context} />} input={input} inputFields={inputFields} result={result} />
}

const forceStateTransitionToolCard: ToolCardRenderer = {
  toolName: "force_state_transition",
  collapsedSummary,
  renderExpanded
}

export default forceStateTransitionToolCard

const longReason = [
  "**Repair state drift** after verifying the workflow has stopped and no active WorkUnit still owns the Job.",
  "",
  "- The latest workflow is terminal.",
  "- No queued Run can advance the Job.",
  "- The operator reviewed the audit snapshot before confirming."
].join("\n")

const longMessage = [
  "Apply **force fail** to JOB-4048?",
  "",
  "This changes only the existing Job state.",
  "",
  "It does not create a Workflow, WorkUnit, or queued Run. Confirm after checking the audit reason, the latest workflow state, and current ownership."
].join("\n")

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: i18n.t("chat:force_state_transition.example_pending"),
    description: i18n.t("chat:force_state_transition.example_pending_description"),
    input: { job_id: 4048, event: "force_fail", reason: longReason },
    parsedResult: {
      pending_confirmation_id: 501,
      pending_action_id: 501,
      state: "pending",
      reason: longReason,
      message: longMessage
    }
  },
  {
    id: "confirmed_transition",
    label: i18n.t("chat:force_state_transition.example_confirmed"),
    description: i18n.t("chat:force_state_transition.example_confirmed_description"),
    input: { job_id: 4048, event: "force_fail", reason: "Repair the stale Job state after the workflow stopped." },
    parsedResult: {
      pending_confirmation_id: 501,
      pending_action_id: 501,
      state: "pending",
      message: i18n.t("chat:force_state_transition.example_confirmed_message")
    },
    livePendingAction: {
      id: 501,
      action: "force_state_transition",
      state: "confirmed",
      label: i18n.t("chat:force_state_transition.example_live_label"),
      detail: "Event: `force_fail`",
      reason: "Repair the stale Job state after the workflow stopped.",
      execution_status: "applied",
      execution_step: "Applied.",
      before_snapshot: { jobs: [{ id: 4048, state: "implemented" }] },
      after_snapshot: { jobs: [{ id: 4048, state: "failed" }] },
      app_confirm_path: "/api/v1/app/chats/7/pending_actions/501/confirm",
      app_reject_path: "/api/v1/app/chats/7/pending_actions/501/reject"
    }
  },
  {
    id: "tool_error",
    label: i18n.t("chat:force_state_transition.example_error"),
    description: i18n.t("chat:force_state_transition.example_error_description"),
    input: { job_id: 9999, event: "force_fail", reason: "Retry after **verifying** the Job identifier." },
    resultBody: "Error: job not found: 9999",
    resultError: true
  }
]
