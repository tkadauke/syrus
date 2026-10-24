import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { parsePendingActionResult, PendingActionResultCard, type PendingActionResult } from "../pendingActionToolCard"
import { Row, StatePill } from "../toolCardUi"

function resumeOutcome(result: PendingActionResult) {
  if (result.kind === "error" || result.kind === "dry_run_evidence") return null
  if (result.state === "confirmed" && (!result.executionStatus || result.executionStatus === "applied")) return "resumed"
  if (result.state === "confirming" || result.executionStatus === "running") return "resuming"
  return result.executionStatus || result.state
}

function ResumeLandingQueueDetails({ result }: { result: PendingActionResult }) {
  const outcome = resumeOutcome(result)
  return (
    <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
      <Row label={i18n.t("chat:resume_landing_queue.target")} value={i18n.t("chat:resume_landing_queue.landing_queue")} />
      {outcome ? <Row label={i18n.t("chat:resume_landing_queue.outcome")} value={<StatePill state={outcome} />} /> : null}
    </dl>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  if (!result) return null
  const outcome = resumeOutcome(result)
  return outcome
    ? i18n.t("chat:resume_landing_queue.summary_with_outcome", {
        outcome: i18n.t(`chat:resume_landing_queue.states.${outcome}`, { defaultValue: outcome.replace(/_/g, " ") })
      })
    : i18n.t("chat:resume_landing_queue.summary")
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? <PendingActionResultCard details={<ResumeLandingQueueDetails result={result} />} result={result} /> : null
}

const resumeLandingQueueToolCard: ToolCardRenderer = {
  toolName: "resume_landing_queue",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export default resumeLandingQueueToolCard

const pendingResult = {
  pending_confirmation_id: 502,
  pending_action_id: 502,
  state: "pending",
  message: "Resume the landing queue?"
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: "Pending queue resume",
    description: "Shows the landing queue target and pending confirmation state before the operator decides.",
    parsedResult: pendingResult
  },
  {
    id: "resumed",
    label: "Landing queue resumed",
    description: "Shows the live applied outcome after the operator confirms the resume.",
    parsedResult: pendingResult,
    livePendingAction: {
      id: 502,
      action: "resume_landing_queue",
      state: "confirmed",
      label: "Resume landing queue",
      detail: null,
      execution_status: "applied",
      execution_step: "Applied.",
      app_confirm_path: "/api/v1/app/chats/7/pending_actions/502/confirm",
      app_reject_path: "/api/v1/app/chats/7/pending_actions/502/reject"
    }
  },
  {
    id: "rejected",
    label: "Queue resume rejected",
    description: "Shows the live rejected outcome while retaining the original resume request.",
    parsedResult: pendingResult,
    livePendingAction: {
      id: 502,
      action: "resume_landing_queue",
      state: "rejected",
      label: "Resume landing queue",
      detail: null,
      app_confirm_path: "/api/v1/app/chats/7/pending_actions/502/confirm",
      app_reject_path: "/api/v1/app/chats/7/pending_actions/502/reject"
    }
  }
]
