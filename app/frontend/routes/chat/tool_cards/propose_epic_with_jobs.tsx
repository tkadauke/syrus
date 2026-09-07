import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, StatePill } from "../toolCardUi"

// Core-owned tool card for propose_epic_with_jobs (EPIC-292 / JOB-4222).
// Unlike propose_job/propose_epic, this tool's payload has no title and no
// `materialized` result — it returns the epic proposal plus its bundled
// child Job proposals (PendingActionsController::Base#payload_for in
// propose_epic_with_jobs_tool.rb), so it gets its own parser.
type ChildProposalRow = { slug: string; state: string; targetRepo: string | null }

type EpicWithJobsOutcome = {
  slug: string
  state: string
  targetEpicLabel: string | null
  dependencyCount: number
  childProposals: ChildProposalRow[]
}

function childProposalRows(value: unknown): ChildProposalRow[] {
  if (!Array.isArray(value)) return []

  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const slug = displayValue(item.slug)
    const state = displayValue(item.state)
    if (!slug || !state) return []
    return [{ slug, state, targetRepo: displayValue(item.target_repo) }]
  })
}

function parseEpicWithJobs(context: ToolCardContext): EpicWithJobsOutcome | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const slug = displayValue(parsed.slug)
  const state = displayValue(parsed.state)
  if (!slug || !state) return null

  return {
    slug,
    state,
    targetEpicLabel: isPlainObject(parsed.target_epic) ? displayValue(parsed.target_epic.label) : null,
    dependencyCount: Array.isArray(parsed.depends_on_proposal_slugs) ? parsed.depends_on_proposal_slugs.length : 0,
    childProposals: childProposalRows(parsed.child_jobs)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const outcome = parseEpicWithJobs(context)
  if (!outcome) return null
  const count = outcome.childProposals.length
  return `Epic proposal: ${outcome.slug} (${outcome.state}, ${count} Job${count === 1 ? "" : "s"})`
}

function renderExpanded(context: ToolCardContext) {
  const outcome = parseEpicWithJobs(context)
  if (!outcome) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>Epic</Badge>
        <StatePill state={outcome.state} />
        <span className="font-mono text-gray-500 dark:text-gray-400">{outcome.slug}</span>
      </div>
      {outcome.targetEpicLabel || outcome.dependencyCount > 0 ? (
        <div className="flex flex-wrap items-center gap-2 text-gray-700 dark:text-gray-300">
          {outcome.targetEpicLabel ? <span>Target epic: <span className="font-mono">{outcome.targetEpicLabel}</span></span> : null}
          {outcome.dependencyCount > 0 ? <Badge>{outcome.dependencyCount} dependenc{outcome.dependencyCount === 1 ? "y" : "ies"}</Badge> : null}
        </div>
      ) : null}
      {outcome.childProposals.length > 0 ? (
        <div>
          <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">
            Child proposals ({outcome.childProposals.length})
          </div>
          <ul className="mt-1 space-y-1">
            {outcome.childProposals.map((child) => (
              <li className="flex flex-wrap items-center gap-2" key={child.slug}>
                <span className="font-mono text-gray-700 dark:text-gray-300">{child.slug}</span>
                <StatePill state={child.state} />
                {child.targetRepo ? <span className="text-gray-500 dark:text-gray-400">{child.targetRepo}</span> : null}
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </CardShell>
  )
}

const proposeEpicWithJobsToolCard: ToolCardRenderer = {
  toolName: "propose_epic_with_jobs",
  collapsedSummary,
  renderExpanded
}

export default proposeEpicWithJobsToolCard
