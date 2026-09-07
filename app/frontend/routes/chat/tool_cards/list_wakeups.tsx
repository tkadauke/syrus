import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, displayValue, EmptyState, numberValue } from "../toolCardUi"

// Core-owned tool card for list_wakeups (EPIC-292 / JOB-4222).
type WakeupRow = { id: string; fireAt: string; delayRemainingMinutes: number | null; promptPreview: string | null }

function parseWakeupRow(value: unknown): WakeupRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const fireAt = displayValue(value.fire_at)
  if (!id || !fireAt) return null

  return {
    id,
    fireAt,
    delayRemainingMinutes: numberValue(value.delay_remaining_minutes),
    promptPreview: displayValue(value.prompt_preview)
  }
}

function wakeupRows(context: ToolCardContext): WakeupRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.wakeups)) return null

  return parsed.wakeups.flatMap((item) => {
    const row = parseWakeupRow(item)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = wakeupRows(context)
  if (!rows) return null
  return `${rows.length} wakeup${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const rows = wakeupRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>No pending wakeups in this chat.</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Wakeup</th>
            <th className="px-2 py-1 font-semibold" scope="col">Fires at</th>
            <th className="px-2 py-1 font-semibold" scope="col">Remaining</th>
            <th className="px-2 py-1 font-semibold" scope="col">Prompt</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.id}>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-800 dark:text-gray-200">#{row.id}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.fireAt}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">
                {row.delayRemainingMinutes != null ? <Badge>{row.delayRemainingMinutes} min</Badge> : "—"}
              </td>
              <td className="max-w-[24rem] truncate px-2 py-1 text-gray-600 dark:text-gray-300" title={row.promptPreview ?? undefined}>{row.promptPreview || "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const listWakeupsToolCard: ToolCardRenderer = {
  toolName: "list_wakeups",
  collapsedSummary,
  renderExpanded
}

export default listWakeupsToolCard
