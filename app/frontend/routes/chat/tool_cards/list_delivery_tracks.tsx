import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, displayValue, EmptyState } from "../toolCardUi"

// Core-owned tool card for list_delivery_tracks (the tool-card work).
type TrackRow = {
  name: string
  isDefault: boolean
  branch: string | null
  reviewGradePhase: string | null
  landingGradePhase: string | null
}

function parseRow(value: unknown): TrackRow | null {
  if (!isPlainObject(value)) return null
  const name = displayValue(value.name)
  if (!name) return null

  return {
    name,
    isDefault: value.default === true,
    branch: displayValue(value.branch),
    reviewGradePhase: displayValue(value.review_grade_phase),
    landingGradePhase: displayValue(value.landing_grade_phase)
  }
}

function parseRows(context: ToolCardContext): TrackRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.tracks)) return null

  return parsed.tracks.flatMap((item) => {
    const row = parseRow(item)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = parseRows(context)
  if (!rows) return null
  return `${rows.length} delivery track${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const rows = parseRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>No delivery tracks configured.</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Track</th>
            <th className="px-2 py-1 font-semibold" scope="col">Branch</th>
            <th className="px-2 py-1 font-semibold" scope="col">Review phase</th>
            <th className="px-2 py-1 font-semibold" scope="col">Landing phase</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.name}>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-800 dark:text-gray-200">
                <span className="flex items-center gap-1">{row.name}{row.isDefault ? <Badge>default</Badge> : null}</span>
              </td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.branch || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.reviewGradePhase || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.landingGradePhase || "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const listDeliveryTracksToolCard: ToolCardRenderer = {
  toolName: "list_delivery_tracks",
  collapsedSummary,
  renderExpanded
}

export default listDeliveryTracksToolCard
