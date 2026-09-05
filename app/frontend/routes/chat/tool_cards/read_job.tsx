import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, Row, StatePill } from "../toolCardUi"

// Core-owned tool card for read_job (EPIC-291 / JOB-4220). Shows the
// canonical JOB id, title, state, PR, branch, priority, agent provider,
// dependencies, and deployment stage when present.
type DependencyBadge = { key: string; label: string; state: string | null; pending: boolean }
type DeploymentStage = { name: string; label: string; reached: boolean }

type JobCard = {
  id: string
  title: string
  state: string
  prNumber: string | null
  branchName: string | null
  priority: string | null
  agentProvider: string | null
  dependencies: DependencyBadge[]
  deploymentStages: DeploymentStage[]
}

function dependencyBadges(value: unknown): DependencyBadge[] {
  if (!Array.isArray(value)) return []

  return value.flatMap((item, index): DependencyBadge[] => {
    if (!isPlainObject(item)) return []

    if (item.pending) {
      const label = displayValue(item.unresolved_ref) || "pending dependency"
      return [{ key: `pending-${index}`, label, state: displayValue(item.unresolved_ref_state), pending: true }]
    }

    if (item.epic_id !== undefined) {
      const epicId = displayValue(item.epic_id)
      if (!epicId) return []
      return [{ key: `epic-${epicId}`, label: displayValue(item.display_number) || `EPIC-${epicId}`, state: displayValue(item.state), pending: false }]
    }

    const jobId = displayValue(item.id)
    if (!jobId) return []
    return [{ key: `job-${jobId}`, label: `JOB-${jobId}`, state: displayValue(item.state), pending: false }]
  })
}

function deploymentStages(value: unknown): DeploymentStage[] {
  if (!Array.isArray(value)) return []

  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const name = displayValue(item.name)
    if (!name) return []
    return [{ name, label: displayValue(item.label) || name, reached: item.reached === true }]
  })
}

function parseJob(context: ToolCardContext): JobCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.job)) return null

  const job = parsed.job
  const id = displayValue(job.id)
  const state = displayValue(job.state)
  if (!id || !state) return null

  return {
    id,
    title: displayValue(job.issue_title) || `JOB-${id}`,
    state,
    prNumber: displayValue(job.pr_number),
    branchName: displayValue(job.branch_name),
    priority: displayValue(job.priority),
    agentProvider: displayValue(job.agent_provider),
    dependencies: dependencyBadges(job.dependencies),
    deploymentStages: deploymentStages(job.deployment_stages)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const job = parseJob(context)
  if (!job) return null
  return `JOB-${job.id} (${job.state})`
}

function renderExpanded(context: ToolCardContext) {
  const job = parseJob(context)
  if (!job) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">JOB-{job.id}</span>
        <StatePill state={job.state} />
        {job.priority ? <Badge>{job.priority} priority</Badge> : null}
        {job.agentProvider ? <Badge>{job.agentProvider}</Badge> : null}
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{job.title}</div>
      {job.prNumber || job.branchName ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {job.prNumber ? <Row label="PR" value={`#${job.prNumber}`} /> : null}
          {job.branchName ? <Row label="Branch" value={job.branchName} /> : null}
        </dl>
      ) : null}
      {job.dependencies.length > 0 ? (
        <div>
          <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">Dependencies</div>
          <div className="mt-1 flex flex-wrap gap-1">
            {job.dependencies.map((dependency) => (
              <span
                className={`rounded-full px-2 py-0.5 text-2xs ${dependency.pending ? "bg-amber-100 text-amber-800 dark:bg-amber-950/40 dark:text-amber-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}
                key={dependency.key}
              >
                {dependency.label}{dependency.state ? ` · ${dependency.state}` : ""}
              </span>
            ))}
          </div>
        </div>
      ) : null}
      {job.deploymentStages.length > 0 ? (
        <div>
          <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">Deployment stage</div>
          <div className="mt-1 flex flex-wrap items-center gap-1">
            {job.deploymentStages.map((stage, index) => (
              <span className="flex items-center gap-1" key={stage.name}>
                <span className={`rounded-full px-2 py-0.5 text-2xs ${stage.reached ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-200" : "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400"}`}>
                  {stage.label}
                </span>
                {index < job.deploymentStages.length - 1 ? <span aria-hidden="true" className="text-gray-300 dark:text-gray-600">→</span> : null}
              </span>
            ))}
          </div>
        </div>
      ) : null}
    </CardShell>
  )
}

const readJobToolCard: ToolCardRenderer = {
  toolName: "read_job",
  collapsedSummary,
  renderExpanded
}

export default readJobToolCard
