import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { CardShell, displayValue, EntityReference, StatePill } from "@app/routes/chat/toolCardUi"
import { t, withScheduledTaskErrors } from "../scheduledTaskToolCard"

// Plugin-owned tool card for fire_scheduled_task_now (the pending-action tool-card work).
// The tool returns the standard pending-action shape
// `{ pending_confirmation_id, pending_action_id, state, message }`, but the
// parser is intentionally self-contained here: reaching into core's
// pending-action card module would couple this plugin to another family's
// private helper.
//
// Purely informational — confirm/reject lives on the separately anchored
// PendingActionCard.
type FireNowCard = {
  actionId: string
  taskId: string | null
  state: string
  message: string | null
  reason: string | null
  fired: boolean | null
  jobId: string | null
  jobHref: string | null
}

function jobFromLiveAction(context: ToolCardContext) {
  const live = context.livePendingAction
  const outcome = isPlainObject(live?.outcome) ? live.outcome : null
  const nestedJob = isPlainObject(outcome?.job) ? outcome.job : null
  const resourceMatch = live?.resource_url?.match(/^\/jobs\/(?:JOB-)?(\d+)(?:[/?#]|$)/i)
  const id = resourceMatch?.[1] || displayValue(outcome?.job_id) || displayValue(nestedJob?.id)
  return { id, href: resourceMatch ? live?.resource_url || null : id ? `/jobs/${id}` : null }
}

function parseFireNow(context: ToolCardContext): FireNowCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const actionId = displayValue(parsed.pending_action_id) || displayValue(parsed.pending_confirmation_id)
  if (!actionId) return null

  const live = context.livePendingAction
  const liveMatch = live && displayValue(live.id) === actionId ? live : null
  const outcome = isPlainObject(liveMatch?.outcome) ? liveMatch.outcome : null
  const job = liveMatch && outcome?.fired !== false ? jobFromLiveAction(context) : { id: null, href: null }

  return {
    actionId,
    taskId: displayValue(context.input?.scheduled_task_id),
    state: liveMatch?.state || displayValue(parsed.state) || "pending",
    message: displayValue(parsed.message),
    reason: displayValue(outcome?.reason) || displayValue(liveMatch?.reason) || displayValue(liveMatch?.execution_error),
    fired: typeof outcome?.fired === "boolean" ? outcome.fired : null,
    jobId: job.id,
    jobHref: job.href
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseFireNow(context)
  if (!card) return null

  if (card.state === "confirmed" && card.fired) return card.jobId ? t("tool_fire_now_fired_summary", { id: card.jobId }) : t("tool_fire_now_confirmed_summary")
  if (card.state === "confirmed" && card.fired === false) return t("tool_fire_now_skipped_summary")
  if (card.state === "confirmed") return t("tool_fire_now_confirmed_summary")
  if (card.state === "rejected") return t("tool_fire_now_rejected_summary")
  if (card.state === "failed") return t("tool_fire_now_failed_summary")
  return t("tool_fire_now_summary", { id: card.actionId, state: card.state })
}

function renderExpanded(context: ToolCardContext) {
  const card = parseFireNow(context)
  if (!card) return null
  const pending = ["queued", "pending", "confirming"].includes(card.state)

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={card.state} />
        <span className="min-w-0 break-words text-sm font-medium text-gray-900 dark:text-gray-100">{t("tool_fire_now_title")}</span>
        <EntityReference id={card.actionId} kind="pending_action" wrap="nowrap" />
      </div>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        {card.taskId ? <EntityReference id={card.taskId} kind="scheduled_task" wrap="nowrap" /> : null}
        {card.jobId ? <EntityReference href={card.jobHref} id={card.jobId} kind="job" wrap="nowrap" /> : null}
      </div>
      <MarkdownPreview
        emptyLabel={t("tool_fire_now_message_empty")}
        linkifySlugs
        linkifyUrls
        maxChars={480}
        modalLabel={t("tool_fire_now_message_full")}
        text={card.message}
        title={t("tool_fire_now_message")}
      />
      {pending ? <div className="break-words text-gray-500 dark:text-gray-400">{t("tool_fire_now_pending_confirmation")}</div> : null}
      {card.state === "confirmed" && card.fired ? <div className="break-words text-success-text">{t("tool_fire_now_fired")}</div> : null}
      {card.state === "confirmed" && card.fired === false ? (
        <div className="break-words text-warning-text">
          {card.reason ? t("tool_fire_now_skipped_reason", { reason: card.reason }) : t("tool_fire_now_skipped")}
        </div>
      ) : null}
      {card.state === "confirmed" && card.fired == null ? <div className="break-words text-success-text">{t("tool_fire_now_confirmed")}</div> : null}
      {card.state === "rejected" ? <div className="break-words text-danger-text">{card.reason || t("tool_fire_now_rejected")}</div> : null}
      {card.state === "failed" ? <div className="break-words text-danger-text">{card.reason || t("tool_fire_now_failed")}</div> : null}
    </CardShell>
  )
}

const fireScheduledTaskNowToolCard: ToolCardRenderer = withScheduledTaskErrors(
  {
    toolName: "fire_scheduled_task_now",
    argumentSummary(input) {
      const taskId = displayValue(input?.scheduled_task_id)
      return taskId ? t("tool_fire_now_argument", { id: taskId }) : ""
    },
    collapsedSummary,
    renderExpanded
  },
  t("tool_fire_now_title")
)

export const examples: ToolCardExample[] = [
  {
    id: "pending_markdown_message",
    label: "Pending immediate fire",
    input: { scheduled_task_id: 12 },
    parsedResult: { pending_confirmation_id: 501, state: "pending", message: "Fire **TASK-12** now? See https://example.test/runbook." }
  },
  {
    id: "confirmed_with_job",
    label: "Confirmed with created Job",
    input: { scheduled_task_id: 12 },
    parsedResult: { pending_action_id: 501, state: "pending", message: "Fire TASK-12 immediately?" },
    livePendingAction: {
      id: 501,
      action: "fire_scheduled_task_now",
      state: "confirmed",
      label: "Fire scheduled task #12",
      detail: "scheduled_task_id: 12",
      outcome: { fired: true, job_id: 884 },
      resource_title: "Scheduled run",
      resource_url: "/jobs/884",
      app_confirm_path: "/confirm",
      app_reject_path: "/reject"
    }
  },
  {
    id: "confirmed_but_skipped",
    label: "Confirmed but skipped",
    input: { scheduled_task_id: 12 },
    parsedResult: { pending_action_id: 502, state: "pending", message: "Fire TASK-12 immediately?" },
    livePendingAction: {
      id: 502,
      action: "fire_scheduled_task_now",
      state: "confirmed",
      label: "Fire scheduled task #12",
      detail: "scheduled_task_id: 12",
      outcome: { fired: false, reason: "already_fired_window" },
      app_confirm_path: "/confirm",
      app_reject_path: "/reject"
    }
  },
  { id: "error", label: "Immediate fire error", input: { scheduled_task_id: 12 }, resultBody: "Task isn't fireable in its current state.", resultError: true },
  { id: "empty", label: "Empty result", input: { scheduled_task_id: 12 }, parsedResult: {} }
]

export default fireScheduledTaskNowToolCard
