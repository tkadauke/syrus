import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "i18next"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { CardShell, displayValue, Row } from "@app/routes/chat/toolCardUi"
import { parseScheduledTaskDetail, ScheduledTaskSummary, withScheduledTaskErrors } from "../scheduledTaskToolCard"

const UPDATE_FIELDS = ["name", "prompt", "schedule_input", "fire_at", "pr_pileup_policy"] as const
type UpdateField = (typeof UPDATE_FIELDS)[number]
const RESULT_FIELDS: Record<UpdateField, string[]> = {
  name: ["label", "name"],
  prompt: ["prompt"],
  schedule_input: ["schedule_input", "schedule_explanation", "cron_expression"],
  fire_at: ["fire_at"],
  pr_pileup_policy: ["pr_pileup_policy"]
}

function taskRecord(value: unknown): Record<string, unknown> | null {
  return isPlainObject(value) && isPlainObject(value.scheduled_task) ? value.scheduled_task : null
}

function matchingPriorTask(context: ToolCardContext, id: string): Record<string, unknown> | null {
  const results = [
    ...(context.priorCalls || []).filter((call) => ["read_scheduled_task", "list_scheduled_tasks"].includes(call.toolName)).map((call) => call.parsedResult),
    context.priorResults?.read_scheduled_task,
    context.priorResults?.list_scheduled_tasks
  ]
  for (const result of results) {
    const direct = taskRecord(result)
    if (direct && displayValue(direct.id) === id) return direct
    if (!isPlainObject(result)) continue
    const tasks = Array.isArray(result.scheduled_tasks) ? result.scheduled_tasks : Array.isArray(result.tasks) ? result.tasks : []
    const match = tasks.find((candidate) => isPlainObject(candidate) && displayValue(candidate.id) === id)
    if (isPlainObject(match)) return match
  }
  return null
}

function fieldValue(record: Record<string, unknown> | null, field: UpdateField): string | null {
  if (!record) return null
  for (const key of RESULT_FIELDS[field]) {
    if (key in record) return displayValue(record[key]) ?? t("tool_empty_value")
  }
  return null
}

function inputFields(context: ToolCardContext) {
  const input = isPlainObject(context.input) ? context.input : {}
  return UPDATE_FIELDS.filter((field) => Object.prototype.hasOwnProperty.call(input, field))
}

function collapsedSummary(context: ToolCardContext) {
  const detail = parseScheduledTaskDetail(context.parsedResult)
  if (!detail) return null

  return t("tool_update_summary", { label: detail.task.label, id: detail.task.id })
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`scheduled_tasks:${key}`, options)
}

function renderExpanded(context: ToolCardContext) {
  const detail = parseScheduledTaskDetail(context.parsedResult)
  if (!detail) return null
  const current = taskRecord(context.parsedResult)
  const previous = matchingPriorTask(context, detail.task.id)
  const fields = inputFields(context)
  const promptChanged = fields.includes("prompt")
  const previousPrompt = promptChanged ? fieldValue(previous, "prompt") : null

  return (
    <CardShell>
      <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("tool_update_title")}</div>
      <ScheduledTaskSummary task={detail.task} />
      {fields.length ? (
        <section className="min-w-0">
          <div className="mb-1 text-xs font-semibold text-text-primary">{t("tool_changed_fields")}</div>
          <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
            {fields
              .filter((field) => field !== "prompt")
              .map((field) => {
                const before = fieldValue(previous, field)
                const after = fieldValue(current, field) ?? fieldValue(context.input || null, field) ?? t("tool_empty_value")
                return <Row key={field} label={t(`tool_field_${field}`)} value={before == null ? after : `${before} → ${after}`} />
              })}
          </dl>
        </section>
      ) : null}
      {promptChanged || detail.prompt != null ? (
        <div className="grid min-w-0 gap-2 sm:grid-cols-2">
          {previousPrompt != null ? (
            <div className="min-w-0">
              {previousPrompt === t("tool_empty_value") ? (
                <div className="mb-1 text-xs font-semibold text-text-primary">{t("tool_previous_prompt")}</div>
              ) : null}
              <MarkdownPreview
                emptyLabel={t("tool_prompt_empty")}
                linkifySlugs
                linkifyUrls
                maxChars={720}
                modalLabel={t("tool_previous_prompt_full")}
                onLinkClick={context.onLinkClick}
                text={previousPrompt === t("tool_empty_value") ? "" : previousPrompt}
                title={previousPrompt === t("tool_empty_value") ? undefined : t("tool_previous_prompt")}
              />
            </div>
          ) : null}
          {!detail.prompt?.trim() ? (
            <div className="min-w-0">
              <div className="mb-1 text-xs font-semibold text-text-primary">{promptChanged ? t("tool_field_prompt") : t("tool_prompt")}</div>
              <MarkdownPreview emptyLabel={t("tool_prompt_empty")} onLinkClick={context.onLinkClick} text={detail.prompt} />
            </div>
          ) : (
            <MarkdownPreview
              emptyLabel={t("tool_prompt_empty")}
              linkifySlugs
              linkifyUrls
              maxChars={720}
              modalLabel={t("tool_prompt_full")}
              onLinkClick={context.onLinkClick}
              text={detail.prompt}
              title={promptChanged ? t("tool_field_prompt") : t("tool_prompt")}
            />
          )}
        </div>
      ) : null}
    </CardShell>
  )
}

const updateScheduledTaskToolCard: ToolCardRenderer = withScheduledTaskErrors({
  toolName: "update_scheduled_task",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
})

export const examples: ToolCardExample[] = [
  {
    id: "partial_update_with_prior_snapshot",
    label: "Partial update with known previous values",
    input: { scheduled_task_id: 12, name: "Weekday health check", prompt: "Check **main** and review JOB-42. See https://example.test/runbook." },
    priorCalls: [
      {
        toolName: "read_scheduled_task",
        input: { scheduled_task_id: 12 },
        parsedResult: { scheduled_task: { id: 12, label: "Nightly health check", prompt: "Check main.", state: "active" } }
      }
    ],
    parsedResult: {
      scheduled_task: {
        id: 12,
        label: "Weekday health check",
        prompt: "Check **main** and review JOB-42. See https://example.test/runbook.",
        state: "active",
        schedule_input: "Every weekday at 5am",
        pr_pileup_policy: "replace"
      }
    }
  },
  {
    id: "validation_error",
    label: "Invalid schedule",
    input: { scheduled_task_id: 12, schedule_input: "whenever" },
    parsedResult: { error: { message: "Schedule could not be parsed." } },
    resultError: true
  }
]

export default updateScheduledTaskToolCard
