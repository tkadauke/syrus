import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"

// Core-owned tool card for list_epics (EPIC-291 / JOB-4220). Renders results
// as a dense table optimized for scanning, mirroring the list_jobs card.
type EpicRow = {
  key: string
  epicId: string
  title: string
  state: string
  repositorySlug: string | null
  childJobCount: number | null
  openJobCount: number | null
}

function displayValue(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) return String(value)
  if (typeof value === "string" && value.trim()) return value.trim()
  return null
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function parseEpicRow(value: unknown): EpicRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const state = displayValue(value.state)
  if (!id || !state) return null

  return {
    key: id,
    epicId: `EPIC-${id}`,
    title: displayValue(value.title) || `EPIC-${id}`,
    state,
    repositorySlug: displayValue(value.repository_slug),
    childJobCount: numberValue(value.child_job_count),
    openJobCount: numberValue(value.open_job_count)
  }
}

function epicRows(context: ToolCardContext): EpicRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.epics)) return null

  return parsed.epics.flatMap((epic) => {
    const row = parseEpicRow(epic)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = epicRows(context)
  if (!rows) return null
  return `${rows.length} Epic${rows.length === 1 ? "" : "s"}`
}

function progressLabel(row: EpicRow) {
  if (row.childJobCount == null) return "—"
  const doneCount = row.childJobCount - (row.openJobCount ?? 0)
  return `${doneCount}/${row.childJobCount} done`
}

function renderExpanded(context: ToolCardContext) {
  const rows = epicRows(context)
  if (!rows) return null

  if (rows.length === 0) {
    return (
      <div className="mt-1 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-xs text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
        No Epics found.
      </div>
    )
  }

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Epic</th>
            <th className="px-2 py-1 font-semibold" scope="col">Title</th>
            <th className="px-2 py-1 font-semibold" scope="col">State</th>
            <th className="px-2 py-1 font-semibold" scope="col">Repository</th>
            <th className="px-2 py-1 font-semibold" scope="col">Progress</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.key}>
              <td className="whitespace-nowrap px-2 py-1 font-mono font-medium text-gray-900 dark:text-gray-100">{row.epicId}</td>
              <td className="max-w-[16rem] truncate px-2 py-1 text-gray-800 dark:text-gray-200" title={row.title}>{row.title}</td>
              <td className="whitespace-nowrap px-2 py-1 capitalize text-gray-600 dark:text-gray-300">{row.state.replace(/_/g, " ")}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.repositorySlug || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{progressLabel(row)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const listEpicsToolCard: ToolCardRenderer = {
  toolName: "list_epics",
  collapsedSummary,
  renderExpanded
}

export default listEpicsToolCard
