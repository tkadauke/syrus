import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, StatePill } from "../toolCardUi"

// Core-owned tool card for read_epic (EPIC-291 / JOB-4220). Shows the
// canonical EPIC id, title, state, repository, dependency badges, and the
// child Job chain/progress.
type DependencyBadge = { key: string; label: string; state: string | null }
type ChildJobRow = { key: string; jobId: string; title: string; state: string }

type EpicCard = {
  id: string
  displayNumber: string
  title: string
  state: string
  repository: string | null
  dependsOnEpics: DependencyBadge[]
  dependentEpics: DependencyBadge[]
  childJobs: ChildJobRow[]
}

function epicDependencyBadges(value: unknown): DependencyBadge[] {
  if (!Array.isArray(value)) return []

  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const id = displayValue(item.id)
    if (!id) return []
    return [{ key: id, label: displayValue(item.display_number) || `EPIC-${id}`, state: displayValue(item.state) }]
  })
}

function childJobRows(value: unknown): ChildJobRow[] {
  if (!Array.isArray(value)) return []

  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const id = displayValue(item.id)
    const state = displayValue(item.state)
    if (!id || !state) return []
    return [{ key: id, jobId: `JOB-${id}`, title: displayValue(item.issue_title) || `JOB-${id}`, state }]
  })
}

function parseEpic(context: ToolCardContext): EpicCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.epic)) return null

  const epic = parsed.epic
  const id = displayValue(epic.id)
  const state = displayValue(epic.state)
  if (!id || !state) return null

  return {
    id,
    displayNumber: displayValue(epic.display_number) || `EPIC-${id}`,
    title: displayValue(epic.title) || `EPIC-${id}`,
    state,
    repository: displayValue(epic.repository),
    dependsOnEpics: epicDependencyBadges(epic.depends_on_epics),
    dependentEpics: epicDependencyBadges(epic.dependent_epics),
    childJobs: childJobRows(parsed.child_jobs)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const epic = parseEpic(context)
  if (!epic) return null
  return `${epic.displayNumber}: ${epic.title}`
}

function isDoneState(state: string) {
  return ["merged", "closed", "approved", "landing"].includes(state)
}

function renderExpanded(context: ToolCardContext) {
  const epic = parseEpic(context)
  if (!epic) return null

  const doneCount = epic.childJobs.filter((job) => isDoneState(job.state)).length

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{epic.displayNumber}</span>
        <StatePill state={epic.state} />
        {epic.repository ? <Badge>{epic.repository}</Badge> : null}
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{epic.title}</div>
      {epic.dependsOnEpics.length > 0 || epic.dependentEpics.length > 0 ? (
        <div className="flex flex-wrap gap-3">
          {epic.dependsOnEpics.length > 0 ? <DependencyGroup badges={epic.dependsOnEpics} label="Depends on" /> : null}
          {epic.dependentEpics.length > 0 ? <DependencyGroup badges={epic.dependentEpics} label="Dependents" /> : null}
        </div>
      ) : null}
      {epic.childJobs.length > 0 ? (
        <div>
          <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">
            Child Jobs ({doneCount}/{epic.childJobs.length})
          </div>
          <ol className="mt-1 flex flex-wrap items-center gap-1">
            {epic.childJobs.map((job, index) => (
              <li className="flex items-center gap-1" key={job.key}>
                <span
                  className={`rounded-full px-2 py-0.5 text-2xs ${isDoneState(job.state) ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}
                  title={job.title}
                >
                  {job.jobId}
                </span>
                {index < epic.childJobs.length - 1 ? <span aria-hidden="true" className="text-gray-300 dark:text-gray-600">→</span> : null}
              </li>
            ))}
          </ol>
        </div>
      ) : null}
    </CardShell>
  )
}

function DependencyGroup({ label, badges }: { label: string; badges: DependencyBadge[] }) {
  return (
    <div>
      <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</div>
      <div className="mt-1 flex flex-wrap gap-1">
        {badges.map((badge) => (
          <span className="rounded-full bg-gray-100 px-2 py-0.5 text-2xs text-gray-600 dark:bg-gray-800 dark:text-gray-300" key={badge.key}>
            {badge.label}{badge.state ? ` · ${badge.state}` : ""}
          </span>
        ))}
      </div>
    </div>
  )
}

const readEpicToolCard: ToolCardRenderer = {
  toolName: "read_epic",
  collapsedSummary,
  renderExpanded
}

export default readEpicToolCard
