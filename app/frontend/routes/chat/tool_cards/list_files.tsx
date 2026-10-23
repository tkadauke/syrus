import { CopyableSlug } from "@app/components/CopyableSlug"
import { formatBytes } from "@app/lib/format"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, numberValue, Row, StatePill } from "../toolCardUi"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

type FileRow = { name: string; isDir: boolean; size: number | null }
type ListFilesResult = { kind: "files"; rows: FileRow[] } | { kind: "pending"; message: string | null }

const failureConfig: ToolFailureConfig = {
  title: "List files",
  attempted: (context) => `List ${displayValue(context.input?.path) || "."}`,
  retrySafety: "safe",
  recovery: "Reconnect the Local Mode daemon or correct the requested path, then retry."
}

function parseResult(context: ToolCardContext): ListFilesResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  if (displayValue(parsed.state)?.toLowerCase() === "pending") return { kind: "pending", message: displayValue(parsed.message) }
  if (!Array.isArray(parsed.files)) return null
  return {
    kind: "files",
    rows: parsed.files.flatMap((item) => {
      if (!isPlainObject(item)) return []
      const name = displayValue(item.name)
      return name ? [{ name, isDir: item.is_dir === true, size: numberValue(item.size) ?? numberValue(item.byte_size) }] : []
    })
  }
}

function sortedRows(rows: FileRow[]) {
  return [...rows].sort((a, b) => (a.isDir !== b.isDir ? (a.isDir ? -1 : 1) : a.name.localeCompare(b.name)))
}

function collapsedSummary(context: ToolCardContext) {
  const failure = toolFailureCollapsedSummary(context, failureConfig)
  if (failure) return failure
  const result = parseResult(context)
  if (!result) return null
  if (result.kind === "pending") return "File listing pending"
  return result.rows.length === 0 ? "No files" : `${result.rows.length} item${result.rows.length === 1 ? "" : "s"}`
}

function FolderIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0 text-amber-600 dark:text-amber-300" fill="none" viewBox="0 0 20 20">
      <path
        d="M2.5 5.5h5l1.5 2h8.5v7.25A1.75 1.75 0 0 1 15.75 16.5H4.25a1.75 1.75 0 0 1-1.75-1.75V5.5Z"
        stroke="currentColor"
        strokeLinejoin="round"
        strokeWidth="1.5"
      />
    </svg>
  )
}

function FileIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0 text-text-muted" fill="none" viewBox="0 0 20 20">
      <path d="M5 2.5h6l4 4v11H5v-15Zm6 0v4h4" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.5" />
    </svg>
  )
}

function InputDetails({ context, path }: { context: ToolCardContext; path: string }) {
  const recursive = context.input?.recursive
  const depth = numberValue(context.input?.depth) ?? numberValue(context.input?.max_depth)
  return (
    <dl className="grid min-w-0 gap-1 sm:grid-cols-3">
      <div className="min-w-0">
        <dt className="text-2xs font-medium uppercase text-text-muted">Path</dt>
        <dd>
          <CopyableSlug className="-ml-1" slug={path} />
        </dd>
      </div>
      {typeof recursive === "boolean" ? <Row label="Recursive" value={recursive ? "Yes" : "No"} /> : null}
      {depth != null ? <Row label="Depth" value={String(depth)} /> : null}
    </dl>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const result = parseResult(context)
  if (!result) return null
  const path = displayValue(context.input?.path) || "."
  if (result.kind === "pending")
    return (
      <CardShell>
        <InputDetails context={context} path={path} />
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state="pending" />
          {result.message ? <span className="break-words text-xs text-text-secondary">{result.message}</span> : null}
        </div>
      </CardShell>
    )

  return (
    <CardShell>
      <InputDetails context={context} path={path} />
      {result.rows.length === 0 ? (
        <EmptyState>{path} is empty.</EmptyState>
      ) : (
        <ul className="max-h-72 min-w-0 space-y-0.5 overflow-auto rounded border border-border bg-surface px-2 py-1 font-mono text-xs">
          {sortedRows(result.rows).map((row) => (
            <li className="flex min-w-0 items-start gap-2 py-0.5" key={row.name}>
              {row.isDir ? <FolderIcon /> : <FileIcon />}
              <span className="min-w-0 flex-1 break-all">
                {row.name}
                {row.isDir ? "/" : ""}
              </span>
              {row.size != null ? <span className="shrink-0 whitespace-nowrap text-text-muted">{formatBytes(row.size)}</span> : null}
            </li>
          ))}
        </ul>
      )}
    </CardShell>
  )
}

export const examples: ToolCardExample[] = [
  {
    id: "files",
    label: "Files and directories",
    input: { path: "app", recursive: false, depth: 1 },
    parsedResult: {
      files: [
        { name: "frontend", is_dir: true },
        { name: "application.rb", is_dir: false, size: 2048 }
      ]
    }
  },
  { id: "empty", label: "Empty directory", input: { path: "tmp/empty" }, parsedResult: { files: [] } },
  { id: "pending", label: "Pending", input: { path: "." }, parsedResult: { state: "pending", message: "Waiting for the local daemon." } },
  {
    id: "error",
    label: "Daemon disconnected",
    input: { path: "." },
    resultBody: "Local daemon not connected. Run `syrus local` in your repo to continue.",
    resultError: true
  }
]

const listFilesToolCard: ToolCardRenderer = { toolName: "list_files", collapsedSummary, renderExpanded }
export default listFilesToolCard
