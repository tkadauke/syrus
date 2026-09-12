import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "i18next"
import { Badge, EmptyState, StatePill } from "@app/routes/chat/toolCardUi"
import { FailureBadge, parseScheduledTask, type ScheduledTaskCard } from "../scheduledTaskToolCard"

// Plugin-owned tool card for list_scheduled_tasks (the pending-action tool-card work).
// Renders the repository's scheduled tasks as a compact schedule table
// instead of a wall of JSON.
function scheduledTasks(context: ToolCardContext): ScheduledTaskCard[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.tasks)) return null

  return parsed.tasks.flatMap((task) => {
    const parsedTask = parseScheduledTask(task)
    return parsedTask ? [parsedTask] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const tasks = scheduledTasks(context)
  if (!tasks) return null

  return t("tool_list_summary", { count: tasks.length })
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`scheduled_tasks:${key}`, options)
}

function renderExpanded(context: ToolCardContext) {
  const tasks = scheduledTasks(context)
  if (!tasks) return null

  if (tasks.length === 0) return <EmptyState>{t("tool_list_empty")}</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_task")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_state")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_kind")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_cadence")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_next_fire")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_health")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {tasks.map((task) => (
            <tr key={task.id}>
              <td className="max-w-[16rem] truncate px-2 py-1 text-gray-800 dark:text-gray-200" title={task.label}>
                <span className="font-mono text-gray-500 dark:text-gray-400">#{task.id}</span> {task.label}
              </td>
              <td className="whitespace-nowrap px-2 py-1"><StatePill state={task.state} /></td>
              <td className="whitespace-nowrap px-2 py-1">{task.kind ? <Badge>{task.kind.replace(/_/g, " ")}</Badge> : "—"}</td>
              <td className="max-w-[16rem] truncate px-2 py-1 text-gray-600 dark:text-gray-300" title={task.cadence ?? undefined}>{task.cadence || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{task.nextFireAt || task.fireAt || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">
                {task.consecutiveFailureCount > 0 ? <FailureBadge count={task.consecutiveFailureCount} /> : "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const listScheduledTasksToolCard: ToolCardRenderer = {
  toolName: "list_scheduled_tasks",
  collapsedSummary,
  renderExpanded
}

export default listScheduledTasksToolCard
