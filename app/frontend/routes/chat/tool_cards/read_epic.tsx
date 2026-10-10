import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EntityReference, StatePill } from "../toolCardUi"

// Core-owned tool card for read_epic (the Tier 1 tool-card work). Shows the
// canonical EPIC id, title, state, repository, dependency badges, and the
// child Job chain/progress.
type DependencyBadge = { key: string; id: string; label: string; state: string | null }
type ChildJobRow = { key: string; id: string; jobId: string; title: string; state: string; dependencies: string[] }

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
    return [{ key: id, id, label: displayValue(item.display_number) || `EPIC-${id}`, state: displayValue(item.state) }]
  })
}

function childJobRows(value: unknown): ChildJobRow[] {
  if (!Array.isArray(value)) return []

  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const id = displayValue(item.id)
    const state = displayValue(item.state)
    if (!id || !state) return []
    return [{ key: id, id, jobId: `JOB-${id}`, title: displayValue(item.issue_title) || `JOB-${id}`, state, dependencies: childJobDependencyLabels(item.depends_on_jobs) }]
  })
}

function childJobDependencyLabels(value: unknown): string[] {
  if (!Array.isArray(value)) return []

  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const id = displayValue(item.id)
    const unresolved = displayValue(item.unresolved_ref)
    const target = id ? `JOB-${id}` : unresolved
    if (!target) return []

    const satisfactionMode = displayValue(item.satisfaction_mode)
    if (satisfactionMode === "deployment_stage") {
      const stage = displayValue(item.required_deployment_stage_name) || "unspecified"
      const latest = latestDeploymentStageLabel(item.latest_deployment_stage)
      return [`${target} · stage ${stage}${latest ? ` · latest ${latest}` : ""}`]
    }

    return [satisfactionMode ? `${target} · ${satisfactionMode}` : target]
  })
}

function latestDeploymentStageLabel(value: unknown) {
  if (!isPlainObject(value)) return null
  return displayValue(value.label) || displayValue(value.name)
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
        <EntityReference id={epic.id} kind="epic" label={epic.displayNumber} slug={epic.displayNumber} />
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
                  <EntityReference id={job.id} kind="job" />
                </span>
                {index < epic.childJobs.length - 1 ? <span aria-hidden="true" className="text-gray-300 dark:text-gray-600">→</span> : null}
              </li>
            ))}
          </ol>
          {epic.childJobs.some((job) => job.dependencies.length > 0) ? (
            <div className="mt-2 flex flex-wrap gap-1">
              {epic.childJobs.flatMap((job) =>
                job.dependencies.map((dependency) => (
                  <span className="rounded-full bg-amber-100 px-2 py-0.5 text-2xs text-amber-800 dark:bg-amber-950/40 dark:text-amber-200" key={`${job.key}-${dependency}`}>
                    {job.jobId} waits for {dependency}
                  </span>
                ))
              )}
            </div>
          ) : null}
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
          <span className="rounded-full bg-surface px-2 py-0.5 text-2xs text-text-secondary" key={badge.key}>
            <EntityReference id={badge.id} kind="epic" label={badge.label} slug={badge.label} />{badge.state ? ` · ${badge.state}` : ""}
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
