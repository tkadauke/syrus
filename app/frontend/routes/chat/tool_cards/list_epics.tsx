import { linkifySlugs } from "../../../lib/linkifySlugs"
import { StatusPill } from "../../../components/StatusPill"
import { stringValue } from "../utils"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "../../../pluginToolCards"

// Core-owned tool card (EPIC-291 / JOB-4220) for `list_epics`: a dense,
// scannable list of Epics (id, state, title, repository, open/total child
// Job count) instead of raw JSON.
type EpicRowData = {
  id: number
  title: string
  state: string
  repositorySlug: string
  openJobCount: number | null
  childJobCount: number | null
}

function parseEpicRow(value: unknown): EpicRowData | null {
  if (!isPlainObject(value) || typeof value.id !== "number") return null

  return {
    id: value.id,
    title: stringValue(value.title).trim(),
    state: stringValue(value.state).trim(),
    repositorySlug: stringValue(value.repository_slug).trim(),
    openJobCount: typeof value.open_job_count === "number" ? value.open_job_count : null,
    childJobCount: typeof value.child_job_count === "number" ? value.child_job_count : null
  }
}

function epicRows(context: ToolCardContext): EpicRowData[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.epics)) return null

  const epics = parsed.epics.flatMap((entry) => {
    const row = parseEpicRow(entry)
    return row ? [row] : []
  })
  return epics.length > 0 ? epics : null
}

function EpicRow({ epic }: { epic: EpicRowData }) {
  return (
    <li className="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-gray-200 py-1.5 last:border-b-0 dark:border-gray-800">
      <span className="shrink-0 font-mono font-medium text-gray-700 dark:text-gray-300">{linkifySlugs(`EPIC-${epic.id}`)}</span>
      {epic.state ? <StatusPill state={epic.state} /> : null}
      <span className="min-w-0 flex-1 truncate text-gray-800 dark:text-gray-100" title={epic.title || undefined}>{epic.title || `EPIC-${epic.id}`}</span>
      {epic.repositorySlug ? <span className="shrink-0 font-mono text-2xs text-gray-500 dark:text-gray-400">{epic.repositorySlug}</span> : null}
      {epic.childJobCount != null ? (
        <span className="shrink-0 text-gray-500 dark:text-gray-400">{epic.openJobCount ?? 0}/{epic.childJobCount} open</span>
      ) : null}
    </li>
  )
}

function renderExpanded(context: ToolCardContext) {
  const epics = epicRows(context)
  if (!epics) return null

  return (
    <ul className="mt-1 divide-y divide-gray-200 rounded border border-gray-200 bg-gray-50 px-2 text-xs dark:divide-gray-800 dark:border-gray-700 dark:bg-gray-900">
      {epics.map((epic) => <EpicRow epic={epic} key={epic.id} />)}
    </ul>
  )
}

const listEpicsToolCard: ToolCardRenderer = {
  toolName: "list_epics",
  renderExpanded
}

export default listEpicsToolCard
