import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import i18n from "@app/i18n"

function DestructiveWarning() {
  return (
    <div className="rounded-[var(--radius-panel)] border border-danger-border bg-danger-surface px-3 py-2 text-danger-text" role="alert">
      <div className="text-xs font-bold uppercase tracking-wide">{i18n.t("chat:emergency_land.warning_title")}</div>
      <div className="mt-1 font-medium">{i18n.t("chat:emergency_land.warning_message")}</div>
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  if (!result) return null
  const warning = result.kind === "standard" && result.state === "pending" ? <DestructiveWarning /> : undefined

  return (
    <PendingActionResultCard
      details={warning}
      input={context.input}
      inputFields={[
        { key: "job_id", label: i18n.t("chat:emergency_land.job"), format: "entity", entityKind: "job" },
        { key: "branch_name", label: i18n.t("chat:emergency_land.branch"), format: "copyable_badge" }
      ]}
      omitBranch
      omitJob
      result={result}
    />
  )
}

const emergencyLandToolCard: ToolCardRenderer = {
  toolName: "emergency_land",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: i18n.t("chat:emergency_land.example_pending"),
    input: { job_id: 4242, branch_name: "syrus/incident-fix" },
    parsedResult: {
      pending_confirmation_id: 7001,
      pending_action_id: 7001,
      state: "pending",
      message: i18n.t("chat:emergency_land.example_pending_message"),
      reason: "Urgent recovery for [the production incident](https://status.example.test/incidents/42)."
    }
  },
  {
    id: "feature_disabled",
    label: i18n.t("chat:emergency_land.example_feature_disabled"),
    input: { job_id: 4242, branch_name: "syrus/incident-fix" },
    resultBody: "Emergency land is not enabled on this instance. Enable it, or use complete_implement_step for the normal handoff path.",
    resultError: true
  }
]

export default emergencyLandToolCard
