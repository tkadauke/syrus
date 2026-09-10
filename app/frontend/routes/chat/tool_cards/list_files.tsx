import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, EmptyState } from "../toolCardUi"

// Local Mode tool card for list_files (the tool-card work).
type FileRow = { name: string; isDir: boolean }

function parseRows(context: ToolCardContext): FileRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.files)) return null

  return parsed.files.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const name = displayValue(item.name)
    if (!name) return []
    return [{ name, isDir: item.is_dir === true }]
  })
}

function sortedRows(rows: FileRow[]): FileRow[] {
  return [ ...rows ].sort((a, b) => {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1
    return a.name.localeCompare(b.name)
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = parseRows(context)
  if (!rows) return null
  return rows.length === 0 ? "No files" : `${rows.length} item${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const rows = parseRows(context)
  if (!rows) return null

  const path = displayValue(context.input?.path) || "."
  if (rows.length === 0) return <EmptyState>{path} is empty.</EmptyState>

  return (
    <div className="mt-1 space-y-1">
      <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{path}</div>
      <ul className="max-h-72 space-y-0.5 overflow-auto rounded border border-gray-200 bg-white px-2 py-1 font-mono text-xs dark:border-gray-800 dark:bg-gray-950">
        {sortedRows(rows).map((row) => (
          <li className="truncate" key={row.name}>{row.isDir ? `${row.name}/` : row.name}</li>
        ))}
      </ul>
    </div>
  )
}

const listFilesToolCard: ToolCardRenderer = {
  toolName: "list_files",
  collapsedSummary,
  renderExpanded
}

export default listFilesToolCard
