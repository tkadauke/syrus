import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { parsePendingActionResult, PendingActionResultCard, type PendingActionResult } from "../pendingActionToolCard"
import { Row, StatePill } from "../toolCardUi"

function wakeOutcome(result: PendingActionResult) {
  if (result.kind === "error" || result.kind === "dry_run_evidence") return null
  if (result.state === "confirmed" && (!result.executionStatus || ["applied", "noop"].includes(result.executionStatus))) return "queued"
  if (result.state === "confirming" || result.executionStatus === "running") return "waking"
  return result.executionStatus || result.state
}

function WakeLandingQueueDetails({ result }: { result: PendingActionResult }) {
  const outcome = wakeOutcome(result)
  return (
    <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
      <Row label={i18n.t("chat:wake_landing_queue.target")} value={i18n.t("chat:wake_landing_queue.landing_queue")} />
      {outcome ? <Row label={i18n.t("chat:wake_landing_queue.outcome")} value={<StatePill state={outcome} />} /> : null}
    </dl>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  if (!result) return null
  const outcome = wakeOutcome(result)
  return outcome
    ? i18n.t("chat:wake_landing_queue.summary_with_outcome", {
        outcome: i18n.t(`chat:wake_landing_queue.states.${outcome}`, { defaultValue: outcome.replace(/_/g, " ") })
      })
    : i18n.t("chat:wake_landing_queue.summary")
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? (
    <PendingActionResultCard
      details={<WakeLandingQueueDetails result={result} />}
      input={context.input}
      inputFields={[{ key: "reason", format: "markdown" }]}
      result={result}
    />
  ) : null
}

const wakeLandingQueueToolCard: ToolCardRenderer = {
  toolName: "wake_landing_queue",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export default wakeLandingQueueToolCard
