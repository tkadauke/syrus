import { linkifySlugs } from "../../../lib/linkifySlugs"
import { StatusPill } from "../../../components/StatusPill"
import { stringValue } from "../utils"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "../../../pluginToolCards"
import { EpicBadge, JobBadge } from "./shared/badges"

// Core-owned tool card (EPIC-291 / JOB-4220) for `read_epic`: the canonical
// EPIC id, title, state, repository, dependency badges (both directions —
// Epics this one depends on, and Epics blocked by it), and a compact
// chain of child Jobs with a landed/total progress readout.
const DONE_JOB_STATES = new Set(["merged", "closed", "no_change_needed"])

function readEpicPayload(context: ToolCardContext): { epic: Record<string, unknown>; childJobs: Record<string, unknown>[] } | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.epic)) return null
  if (typeof parsed.epic.id !== "number") return null

  const childJobs = Array.isArray(parsed.child_jobs) ? parsed.child_jobs.filter(isPlainObject) : []
  return { epic: parsed.epic, childJobs }
}

function epicReferences(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) return []
  return value.filter((item): item is Record<string, unknown> => isPlainObject(item) && typeof item.id === "number")
}

function EpicReferenceList({ label, epics }: { label: string; epics: Record<string, unknown>[] }) {
  if (epics.length === 0) return null

  return (
    <div>
      <div className="mb-1 font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</div>
      <div className="flex flex-wrap gap-1.5">
        {epics.map((epic) => (
          <EpicBadge id={epic.id as number} key={epic.id as number} state={stringValue(epic.state) || null} title={stringValue(epic.title) || null} />
        ))}
      </div>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const payload = readEpicPayload(context)
  if (!payload) return null

  const { epic, childJobs } = payload
  const id = epic.id as number
  const title = stringValue(epic.title).trim() || `EPIC-${id}`
  const state = stringValue(epic.state).trim()
  const repository = stringValue(epic.repository).trim()
  const dependsOn = epicReferences(epic.depends_on_epics)
  const blocks = epicReferences(epic.dependent_epics)
  const doneCount = childJobs.filter((job) => DONE_JOB_STATES.has(stringValue(job.state))).length

  return (
    <div className="mt-1 space-y-3 rounded border border-gray-200 bg-gray-50 p-3 text-xs dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-medium text-gray-700 dark:text-gray-300">{linkifySlugs(`EPIC-${id}`)}</span>
        {state ? <StatusPill state={state} /> : null}
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{title}</div>
      {repository ? (
        <div>
          <dt className="font-semibold uppercase text-gray-500 dark:text-gray-400">Repository</dt>
          <dd className="font-mono text-gray-800 dark:text-gray-200">{repository}</dd>
        </div>
      ) : null}
      <EpicReferenceList epics={dependsOn} label="Depends on" />
      <EpicReferenceList epics={blocks} label="Blocks" />
      {childJobs.length > 0 ? (
        <div>
          <div className="mb-1 flex items-center justify-between">
            <span className="font-semibold uppercase text-gray-500 dark:text-gray-400">Child Jobs</span>
            <span className="text-gray-500 dark:text-gray-400">{doneCount}/{childJobs.length} landed</span>
          </div>
          <div className="flex flex-wrap gap-1.5">
            {childJobs.map((job) => (
              typeof job.id === "number" ? (
                <JobBadge id={job.id} key={job.id} state={stringValue(job.state) || null} title={stringValue(job.issue_title) || null} />
              ) : null
            ))}
          </div>
        </div>
      ) : null}
    </div>
  )
}

const readEpicToolCard: ToolCardRenderer = {
  toolName: "read_epic",
  renderExpanded
}

export default readEpicToolCard
