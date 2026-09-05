import { linkifySlugs } from "../../../lib/linkifySlugs"
import { StatusPill } from "../../../components/StatusPill"
import { DeploymentStagePipeline } from "../../../components/DeploymentStagePipeline"
import type { JobDeploymentStage } from "../../../api/jobs"
import { stringValue } from "../utils"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "../../../pluginToolCards"
import { EpicBadge, JobBadge, PendingDependencyBadge, PriorityPill } from "./shared/badges"

// Core-owned tool card (EPIC-291 / JOB-4220) for `read_job`: the canonical
// JOB id, title, state, PR, branch, priority, agent provider, dependency
// badges, and — when the Job has landed and the repository tracks
// deployment stages — the same stage pipeline the Job detail page shows.
function jobDetail(context: ToolCardContext): Record<string, unknown> | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.job)) return null
  if (typeof parsed.job.id !== "number") return null

  return parsed.job
}

function jobDeploymentStages(value: unknown): JobDeploymentStage[] | null {
  if (!Array.isArray(value) || value.length === 0) return null

  const stages = value.flatMap((entry) => {
    if (!isPlainObject(entry) || typeof entry.name !== "string" || typeof entry.label !== "string") return []
    return [{
      name: entry.name,
      label: entry.label,
      reached: entry.reached === true,
      reached_at: typeof entry.reached_at === "string" ? entry.reached_at : null,
      tag_sha: typeof entry.tag_sha === "string" ? entry.tag_sha : null
    }]
  })

  return stages.length > 0 ? stages : null
}

function DependencyBadge({ dependency }: { dependency: unknown }) {
  if (!isPlainObject(dependency)) return null

  if (dependency.pending === true) {
    const label = stringValue(dependency.unresolved_ref).trim() || "Pending dependency"
    return <PendingDependencyBadge label={label} />
  }

  if (typeof dependency.epic_id === "number") {
    return <EpicBadge id={dependency.epic_id} state={stringValue(dependency.state) || null} title={stringValue(dependency.title) || null} />
  }

  if (typeof dependency.id === "number") {
    return <JobBadge id={dependency.id} state={stringValue(dependency.state) || null} title={stringValue(dependency.issue_title) || null} />
  }

  return null
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <dt className="font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="truncate font-mono text-gray-800 dark:text-gray-200" title={value}>{value}</dd>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const job = jobDetail(context)
  if (!job) return null

  const id = job.id as number
  const title = stringValue(job.issue_title).trim() || `JOB-${id}`
  const state = stringValue(job.state).trim()
  const priority = stringValue(job.priority).trim()
  const agentProvider = stringValue(job.agent_provider).trim()
  const branch = stringValue(job.branch_name).trim()
  const prNumber = typeof job.pr_number === "number" ? job.pr_number : null
  const dependencies = Array.isArray(job.dependencies) ? job.dependencies : []
  const deploymentStages = jobDeploymentStages(job.deployment_stages)

  return (
    <div className="mt-1 space-y-3 rounded border border-gray-200 bg-gray-50 p-3 text-xs dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-medium text-gray-700 dark:text-gray-300">{linkifySlugs(`JOB-${id}`)}</span>
        {state ? <StatusPill state={state} /> : null}
        {priority ? <PriorityPill priority={priority} /> : null}
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{title}</div>
      {prNumber != null || branch || agentProvider ? (
        <dl className="grid gap-2 sm:grid-cols-3">
          {prNumber != null ? <Field label="PR" value={`#${prNumber}`} /> : null}
          {branch ? <Field label="Branch" value={branch} /> : null}
          {agentProvider ? <Field label="Agent" value={agentProvider} /> : null}
        </dl>
      ) : null}
      {dependencies.length > 0 ? (
        <div>
          <div className="mb-1 font-semibold uppercase text-gray-500 dark:text-gray-400">Dependencies</div>
          <div className="flex flex-wrap gap-1.5">
            {dependencies.map((dependency, index) => <DependencyBadge dependency={dependency} key={`dep-${index}`} />)}
          </div>
        </div>
      ) : null}
      {deploymentStages ? <DeploymentStagePipeline stages={deploymentStages} /> : null}
    </div>
  )
}

const readJobToolCard: ToolCardRenderer = {
  toolName: "read_job",
  renderExpanded
}

export default readJobToolCard
