import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { parsePendingActionResult, PendingActionResultCard, type PendingActionResult } from "../pendingActionToolCard"
import { Row, StatePill } from "../toolCardUi"

function pauseOutcome(result: PendingActionResult) {
  if (result.kind === "error" || result.kind === "dry_run_evidence") return null
  if (result.state === "confirmed" && (!result.executionStatus || result.executionStatus === "applied")) return "paused"
  if (result.state === "confirming" || result.executionStatus === "running") return "pausing"
  return result.executionStatus || result.state
}

function PauseLandingQueueDetails({ result }: { result: PendingActionResult }) {
  const outcome = pauseOutcome(result)
  return (
    <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
      <Row
        label={i18n.t("chat:pause_landing_queue.target")}
        value={
          <a className="font-medium text-brand hover:underline" href="/dashboard/jobs">
            {i18n.t("chat:pause_landing_queue.landing_queue")}
          </a>
        }
      />
      {outcome ? <Row label={i18n.t("chat:pause_landing_queue.outcome")} value={<StatePill state={outcome} />} /> : null}
    </dl>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  if (!result) return null
  const outcome = pauseOutcome(result)
  return outcome
    ? i18n.t("chat:pause_landing_queue.summary_with_outcome", {
        outcome: i18n.t(`chat:pause_landing_queue.states.${outcome}`, { defaultValue: outcome.replace(/_/g, " ") })
      })
    : i18n.t("chat:pause_landing_queue.summary")
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? <PendingActionResultCard details={<PauseLandingQueueDetails result={result} />} result={result} /> : null
}

const pauseLandingQueueToolCard: ToolCardRenderer = {
  toolName: "pause_landing_queue",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export default pauseLandingQueueToolCard
