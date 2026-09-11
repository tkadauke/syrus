import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, EmptyState } from "../toolCardUi"

// Local Mode tool card for git_status (the tool-card work). Parses raw
// `git status --porcelain` lines into a per-file category so the reviewer
// gets a scannable summary instead of raw two-letter status codes.
type Category = "untracked" | "added" | "deleted" | "renamed" | "modified" | "other"

type StatusRow = { code: string; path: string; category: Category }

const CATEGORY_LABEL: Record<Category, string> = {
  untracked: "untracked",
  added: "added",
  deleted: "deleted",
  renamed: "renamed",
  modified: "modified",
  other: "other"
}

function categorize(code: string): Category {
  if (code === "??") return "untracked"
  if (code.includes("A")) return "added"
  if (code.includes("D")) return "deleted"
  if (code.includes("R")) return "renamed"
  if (code.includes("M")) return "modified"
  return "other"
}

function parseLine(line: string): StatusRow | null {
  if (line.length < 3) return null
  const code = line.slice(0, 2)
  const path = line.slice(3).trim()
  if (!path) return null
  return { code, path, category: categorize(code) }
}

function parseStatus(context: ToolCardContext): string | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.status !== "string") return null
  return parsed.status
}

function statusRows(status: string): StatusRow[] {
  return status.split(/\r?\n/).flatMap((line) => {
    const row = parseLine(line)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const status = parseStatus(context)
  if (status == null) return null
  const rows = statusRows(status)
  return rows.length === 0 ? "Working tree clean" : `${rows.length} changed file${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const status = parseStatus(context)
  if (status == null) return null

  const rows = statusRows(status)
  if (rows.length === 0) return <EmptyState>Working tree clean.</EmptyState>

  return (
    <div className="mt-1 max-h-72 space-y-0.5 overflow-auto rounded border border-gray-200 bg-white px-2 py-1 font-mono text-xs dark:border-gray-800 dark:bg-gray-950">
      {rows.map((row, index) => (
        <div className="flex items-center gap-2 truncate" key={`${row.path}-${index}`}>
          <Badge>{CATEGORY_LABEL[row.category]}</Badge>
          <span className="truncate" title={row.path}>
            {row.path}
          </span>
        </div>
      ))}
    </div>
  )
}

const gitStatusToolCard: ToolCardRenderer = {
  toolName: "git_status",
  collapsedSummary,
  renderExpanded
}

export default gitStatusToolCard
