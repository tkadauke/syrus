import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, EntityReference, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { parseScheduledTaskOutcome, ScheduledTaskOutcomeCard, t, withScheduledTaskErrors } from "../scheduledTaskToolCard"

// Plugin-owned tool card for pause_scheduled_task (the pending-action tool-card work).
// Payload: { scheduled_task_id, label, enabled: false }.
function collapsedSummary(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  return t("tool_paused_summary", { label: outcome.label, id: outcome.id })
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseScheduledTaskOutcome(context.parsedResult)
  if (!outcome) return null

  if (outcome.previousState || outcome.state || outcome.nextFireAt || outcome.repositorySlug) {
    return (
      <CardShell>
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <EntityReference id={outcome.id} kind="scheduled_task" wrap="nowrap" />
          {outcome.previousState ? <StatePill state={outcome.previousState} /> : null}
          {outcome.previousState && outcome.state ? <span className="text-text-muted">→</span> : null}
          {outcome.state ? <StatePill state={outcome.state} tone="warning" /> : null}
        </div>
        <div className="min-w-0 break-words text-sm font-medium text-text-primary">{outcome.label}</div>
        <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
          {outcome.repositorySlug ? (
            <div className="min-w-0">
              <div className="text-2xs font-semibold uppercase tracking-wide text-text-muted">{t("tool_repository")}</div>
              <EntityReference kind="repository" repositoryId={outcome.repositoryId} repositorySlug={outcome.repositorySlug} />
            </div>
          ) : null}
          {outcome.nextFireAt ? <Row label={t("tool_previous_next_fire")} value={outcome.nextFireAt} /> : null}
        </dl>
        <div className="text-text-secondary">{t("tool_paused_detail")}</div>
      </CardShell>
    )
  }

  return <ScheduledTaskOutcomeCard detail={t("tool_paused_detail")} outcome={outcome} pill={t("tool_paused")} tone="warning" />
}

const pauseScheduledTaskToolCard: ToolCardRenderer = withScheduledTaskErrors({
  toolName: "pause_scheduled_task",
  collapsedSummary,
  renderExpanded
})

export default pauseScheduledTaskToolCard

export const examples: ToolCardExample[] = [
  {
    id: "paused_task",
    label: "Paused scheduled task",
    input: { scheduled_task_id: 12 },
    parsedResult: {
      scheduled_task_id: 12,
      label: "Nightly main-branch health check",
      enabled: false,
      previous_state: "scheduled",
      state: "paused",
      next_fire_at: "2026-10-24T03:00:00Z",
      repository_id: 4,
      repository_slug: "tkadauke/syrus"
    }
  },
  {
    id: "already_disabled",
    label: "Already disabled error",
    input: { scheduled_task_id: 12 },
    resultBody: "scheduled task is already disabled",
    resultError: true
  }
]
