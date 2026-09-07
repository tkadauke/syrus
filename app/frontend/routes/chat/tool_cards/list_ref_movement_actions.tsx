import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, displayValue, EmptyState } from "../toolCardUi"

// Core-owned tool card for list_ref_movement_actions (EPIC-293 / JOB-4225).
type ActionRow = { name: string; enabled: boolean; mode: string | null; available: boolean; blockedReason: string | null }

function parseRow(value: unknown): ActionRow | null {
  if (!isPlainObject(value)) return null
  const name = displayValue(value.name)
  if (!name) return null

  return {
    name,
    enabled: value.enabled === true,
    mode: displayValue(value.mode),
    available: value.available === true,
    blockedReason: displayValue(value.blocked_reason)
  }
}

function parseRows(context: ToolCardContext): ActionRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.ref_movement_actions)) return null

  return parsed.ref_movement_actions.flatMap((item) => {
    const row = parseRow(item)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = parseRows(context)
  if (!rows) return null
  const availableCount = rows.filter((row) => row.available).length
  return `${availableCount}/${rows.length} ref movement action${rows.length === 1 ? "" : "s"} available`
}

function renderExpanded(context: ToolCardContext) {
  const rows = parseRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>No ref movement actions configured.</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Action</th>
            <th className="px-2 py-1 font-semibold" scope="col">Mode</th>
            <th className="px-2 py-1 font-semibold" scope="col">Availability</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.name}>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-800 dark:text-gray-200">{row.name}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.mode || "—"}</td>
              <td className="px-2 py-1 text-gray-600 dark:text-gray-300">
                {row.available ? <Badge>available</Badge> : <span title={row.blockedReason ?? undefined}>{row.blockedReason || "blocked"}</span>}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const listRefMovementActionsToolCard: ToolCardRenderer = {
  toolName: "list_ref_movement_actions",
  collapsedSummary,
  renderExpanded
}

export default listRefMovementActionsToolCard
