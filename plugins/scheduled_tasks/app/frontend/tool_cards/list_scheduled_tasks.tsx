import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/toolCardParsing"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { Badge, CardShell, EmptyState, EntityReference, Row, StatePill, displayValue } from "@app/routes/chat/toolCardUi"
import { FailureBadge, parseScheduledTask, withScheduledTaskErrors, type ScheduledTaskCard } from "../scheduledTaskToolCard"
import i18n from "i18next"

type ListedTask = ScheduledTaskCard & { prompt: string | null }

function resultPayload(parsed: unknown): Record<string, unknown> | null {
  let value = normalizedToolCardParsedResult(parsed)
  for (let index = 0; index < 2 && isPlainObject(value); index += 1) {
    if (Array.isArray(value.tasks)) return value
    value = value.result ?? value.data
  }
  return isPlainObject(value) && Array.isArray(value.tasks) ? value : null
}

function scheduledTasks(context: ToolCardContext): ListedTask[] | null {
  const payload = resultPayload(context.parsedResult)
  if (!payload) return null
  return (payload.tasks as unknown[]).flatMap((value) => {
    const task = parseScheduledTask(value)
    return task && isPlainObject(value) ? [{ ...task, prompt: displayValue(value.prompt) }] : []
  })
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`scheduled_tasks:${key}`, options)
}

function collapsedSummary(context: ToolCardContext) {
  const tasks = scheduledTasks(context)
  return tasks ? t("tool_list_summary", { count: tasks.length }) : null
}

function TaskLink({ task }: { task: ListedTask }) {
  return <EntityReference id={task.id} kind="scheduled_task" label={task.label} slug={`TASK-${task.id}`} wrap="break" />
}

function RepositoryLink({ slug }: { slug: string | null }) {
  return slug ? <EntityReference href={`https://github.com/${slug}`} kind="repository" repositorySlug={slug} wrap="break" /> : <>—</>
}

function Prompt({ task }: { task: ListedTask }) {
  return task.prompt != null ? (
    <MarkdownPreview linkifySlugs linkifyUrls maxChars={360} maxLines={3} modalLabel={t("tool_prompt_full")} text={task.prompt} title={t("tool_prompt")} />
  ) : null
}

function Status({ task }: { task: ListedTask }) {
  return (
    <div className="flex flex-wrap items-center gap-1">
      <StatePill state={task.state} />
      {task.enabled != null ? <Badge>{t(task.enabled ? "tool_enabled" : "tool_disabled")}</Badge> : null}
      <FailureBadge count={task.consecutiveFailureCount} />
    </div>
  )
}

function valueForInput(value: unknown) {
  const redacted = redactToolCardValue(value)
  return typeof redacted === "string" ? redacted : JSON.stringify(redacted)
}

function InputFilters({ input }: { input?: Record<string, unknown> }) {
  if (!input || Object.keys(input).length === 0) return null
  return (
    <div className="flex min-w-0 flex-wrap items-end gap-x-4 gap-y-2">
      {Object.entries(input).map(([key, value]) => (
        <Row key={key} label={key.replace(/_/g, " ")} value={valueForInput(value)} />
      ))}
    </div>
  )
}

function MobileTask({ task }: { task: ListedTask }) {
  return (
    <li className="min-w-0 space-y-2 rounded border border-border bg-surface p-2">
      <TaskLink task={task} />
      <Status task={task} />
      <dl className="grid min-w-0 grid-cols-2 gap-2 [&_dd]:break-words">
        <Row label={t("tool_repository")} value={<RepositoryLink slug={task.repositorySlug} />} />
        <Row label={t("tool_col_kind")} value={task.kind?.replace(/_/g, " ") || "—"} />
        <Row label={t("tool_col_cadence")} value={task.scheduleTimezone ? `${task.cadence || "—"} (${task.scheduleTimezone})` : task.cadence || "—"} />
        <Row label={t("tool_col_next_fire")} value={task.nextFireAt || task.fireAt || "—"} />
        <Row label={t("tool_last_fired")} value={task.lastFiredAt || "—"} />
        <Row label={t("tool_last_success")} value={task.lastSuccessfulFireAt || "—"} />
        <Row label={t("tool_pr_pileup")} value={task.prPileupPolicy || "—"} />
        <Row label={t("tool_created")} value={task.createdAt || "—"} />
      </dl>
      <Prompt task={task} />
    </li>
  )
}

function renderExpanded(context: ToolCardContext) {
  const tasks = scheduledTasks(context)
  if (!tasks) return null
  return (
    <CardShell>
      <InputFilters input={context.input} />
      {tasks.length === 0 ? (
        <EmptyState>{t("tool_list_empty")}</EmptyState>
      ) : (
        <>
          <ul className="space-y-2 sm:hidden">
            {tasks.map((task) => (
              <MobileTask key={task.id} task={task} />
            ))}
          </ul>
          <div className="hidden min-w-0 overflow-hidden rounded border border-border sm:block">
            <table className="w-full table-fixed text-left text-xs">
              <thead className="bg-subtle text-2xs uppercase text-text-muted">
                <tr>
                  {["tool_col_task", "tool_repository", "tool_col_state", "tool_col_cadence", "tool_col_next_fire", "tool_last_fired", "tool_pr_pileup"].map(
                    (key) => (
                      <th className="px-2 py-1 font-semibold" key={key} scope="col">
                        {t(key)}
                      </th>
                    )
                  )}
                </tr>
              </thead>
              <tbody className="divide-y divide-border bg-surface">
                {tasks.map((task) => (
                  <tr className="align-top" key={task.id}>
                    <td className="min-w-0 break-words px-2 py-2">
                      <TaskLink task={task} />
                      <Prompt task={task} />
                    </td>
                    <td className="break-words px-2 py-2">
                      <RepositoryLink slug={task.repositorySlug} />
                    </td>
                    <td className="px-2 py-2">
                      <Status task={task} />
                      {task.kind ? <div className="mt-1 break-words text-text-muted">{task.kind.replace(/_/g, " ")}</div> : null}
                    </td>
                    <td className="break-words px-2 py-2 text-text-muted">
                      {task.scheduleTimezone ? `${task.cadence || "—"} (${task.scheduleTimezone})` : task.cadence || "—"}
                    </td>
                    <td className="break-all px-2 py-2 text-text-muted">{task.nextFireAt || task.fireAt || "—"}</td>
                    <td className="break-all px-2 py-2 text-text-muted">
                      <div>{task.lastFiredAt || "—"}</div>
                      {task.lastSuccessfulFireAt ? (
                        <div className="mt-1">
                          {t("tool_last_success")}: {task.lastSuccessfulFireAt}
                        </div>
                      ) : null}
                      {task.createdAt ? (
                        <div className="mt-1">
                          {t("tool_created")}: {task.createdAt}
                        </div>
                      ) : null}
                    </td>
                    <td className="break-words px-2 py-2 text-text-muted">{task.prPileupPolicy || "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </CardShell>
  )
}

const listScheduledTasksToolCard: ToolCardRenderer = withScheduledTaskErrors({ toolName: "list_scheduled_tasks", collapsedSummary, renderExpanded })
export default listScheduledTasksToolCard

export const examples: ToolCardExample[] = [
  {
    id: "cron_and_one_shot",
    label: "Scheduled tasks with complete metadata",
    input: { state: "active", repository_slug: "tkadauke/syrus" },
    parsedResult: {
      tasks: [
        {
          id: "9",
          label: "Nightly dependency audit",
          state: "active",
          kind: "cron",
          repository_slug: "tkadauke/syrus",
          cron_expression: "0 3 * * *",
          next_fire_at: "2026-09-17T03:00:00Z",
          last_fired_at: "2026-09-16T03:00:00Z",
          pr_pileup_policy: "skip",
          enabled: true,
          prompt: "Review **dependency health** and see https://example.test/runbook.",
          consecutive_failure_count: 0
        },
        {
          id: "14",
          label: "One-shot incident summary",
          state: "paused",
          kind: "one_shot",
          repository_slug: "tkadauke/syrus",
          fire_at: "2026-09-16T18:00:00Z",
          pr_pileup_policy: "allow",
          enabled: false,
          consecutive_failure_count: 3
        }
      ]
    }
  },
  { id: "no_scheduled_tasks", label: "No scheduled tasks", parsedResult: { tasks: [] } },
  {
    id: "scheduled_tasks_error",
    label: "Scheduled task list error",
    resultError: true,
    parsedResult: { error: { message: "Scheduled tasks are temporarily unavailable." } }
  }
]
