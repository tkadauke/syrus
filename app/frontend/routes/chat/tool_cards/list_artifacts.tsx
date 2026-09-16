import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, displayValue, EmptyState, numberValue } from "../toolCardUi"

type ArtifactRow = {
  type: string
  title: string | null
  contentType: string | null
  byteSize: number | null
  runId: string | null
  stepId: string | null
  iteration: string | null
}

function parseArtifactRow(value: unknown): ArtifactRow | null {
  if (!isPlainObject(value)) return null
  const type = displayValue(value.type)
  if (!type) return null

  return {
    type,
    title: displayValue(value.title),
    contentType: displayValue(value.content_type),
    byteSize: numberValue(value.byte_size),
    runId: displayValue(value.run_id),
    stepId: displayValue(value.step_id),
    iteration: displayValue(value.iteration)
  }
}

function artifactRows(context: ToolCardContext): ArtifactRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.artifacts)) return null

  return parsed.artifacts.flatMap((item) => {
    const row = parseArtifactRow(item)
    return row ? [row] : []
  })
}

function formatBytes(bytes: number | null): string | null {
  if (bytes == null) return null
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function listArtifactsSummary(context: ToolCardContext) {
  const rows = artifactRows(context)
  if (!rows) return null
  return rows.length === 0 ? "No artifacts" : `${rows.length} artifact${rows.length === 1 ? "" : "s"}`
}

export function ArtifactListCard({ rows }: { rows: ArtifactRow[] }) {
  if (rows.length === 0) return <EmptyState>No artifacts recorded on this Workflow.</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Type</th>
            <th className="px-2 py-1 font-semibold" scope="col">Title</th>
            <th className="px-2 py-1 font-semibold" scope="col">Content type</th>
            <th className="px-2 py-1 font-semibold" scope="col">Size</th>
            <th className="px-2 py-1 font-semibold" scope="col">Run / Step</th>
            <th className="px-2 py-1 font-semibold" scope="col">Iteration</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.type}>
              <td className="max-w-56 px-2 py-1">
                <span className="font-mono text-gray-800 dark:text-gray-200" title={row.type}>{row.type}</span>
              </td>
              <td className="max-w-56 truncate px-2 py-1 text-gray-700 dark:text-gray-300" title={row.title || undefined}>
                {row.title || <span className="text-gray-400">-</span>}
              </td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.contentType || <span className="text-gray-400">-</span>}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{formatBytes(row.byteSize) || <span className="text-gray-400">-</span>}</td>
              <td className="whitespace-nowrap px-2 py-1">
                <div className="flex flex-wrap gap-1">
                  {row.runId ? <Badge>RUN-{row.runId}</Badge> : null}
                  {row.stepId ? <Badge>STEP-{row.stepId}</Badge> : null}
                  {!row.runId && !row.stepId ? <span className="text-gray-400">-</span> : null}
                </div>
              </td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.iteration ?? <span className="text-gray-400">-</span>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export function renderArtifactList(context: ToolCardContext) {
  const rows = artifactRows(context)
  return rows ? <ArtifactListCard rows={rows} /> : null
}

const listArtifactsToolCard: ToolCardRenderer = {
  toolName: "list_artifacts",
  collapsedSummary: listArtifactsSummary,
  renderExpanded: renderArtifactList
}

export default listArtifactsToolCard
