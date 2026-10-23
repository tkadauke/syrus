import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell } from "@app/routes/chat/toolCardUi"
import { parseScheduledTaskDetail, PromptDisclosure, scheduledTaskHeadline, ScheduledTaskSummary, withScheduledTaskErrors } from "../scheduledTaskToolCard"

// Plugin-owned tool card for read_scheduled_task (the pending-action tool-card work).
// Payload is `{ scheduled_task: <scheduled_task_payload>.merge(prompt:) }`;
// the prompt is usually long, so it hides behind a disclosure.
function collapsedSummary(context: ToolCardContext) {
  const detail = parseScheduledTaskDetail(context.parsedResult)
  if (!detail) return null

  return scheduledTaskHeadline(detail.task)
}

function renderExpanded(context: ToolCardContext) {
  const detail = parseScheduledTaskDetail(context.parsedResult)
  if (!detail) return null

  return (
    <CardShell>
      <ScheduledTaskSummary task={detail.task} />
      {detail.hasPrompt ? <PromptDisclosure onLinkClick={context.onLinkClick} prompt={detail.prompt} /> : null}
    </CardShell>
  )
}

const readScheduledTaskToolCard: ToolCardRenderer = withScheduledTaskErrors({
  toolName: "read_scheduled_task",
  collapsedSummary,
  renderExpanded
})

export default readScheduledTaskToolCard

export const examples: ToolCardExample[] = [
  {
    id: "recurring_task_details",
    label: "Recurring task details",
    input: { scheduled_task_id: 12 },
    parsedResult: {
      scheduled_task: {
        id: 12,
        repository_id: 7,
        repository_slug: "tkadauke/syrus",
        label: "Nightly main-branch health check",
        kind: "cron",
        state: "scheduled",
        cron_expression: "0 3 * * *",
        schedule_input: "Every day at 3am",
        schedule_expression: "0 3 * * *",
        schedule_explanation: "Runs daily at 3:00 AM UTC",
        schedule_timezone: "UTC",
        pr_pileup_policy: "skip",
        enabled: true,
        next_fire_at: "2026-09-06T03:00:00Z",
        last_fired_at: "2026-09-05T03:00:00Z",
        last_successful_fire_at: "2026-09-05T03:00:00Z",
        consecutive_failure_count: 0,
        created_at: "2026-08-01T00:00:00Z",
        prompt: "Survey **main** for failing graders, check https://example.test/status, and update JOB-42."
      }
    }
  },
  {
    id: "blank_prompt",
    label: "Task with a blank prompt",
    parsedResult: { scheduled_task: { id: 13, label: "Paused audit", state: "paused", enabled: false, prompt: " " } }
  },
  { id: "not_found", label: "Task not found", resultBody: "scheduled task not found: 404", resultError: true }
]
