import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, StatePill } from "../toolCardUi"
import { parseProposalOutcome } from "../proposalToolCard"

// Core-owned tool card for delete_proposal (EPIC-292 / JOB-4222). Shows the
// withdrawn slug plus any cascade of downstream proposals withdrawn with it
// (delete_proposal_tool.rb's `cascade`).
type DeleteProposalResult = { slug: string; state: string; cascadeSlugs: string[] }

function parseDeleteProposal(context: ToolCardContext): DeleteProposalResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const slug = displayValue(parsed.slug)
  const state = displayValue(parsed.state)
  if (!slug || !state) return null

  const cascadeSlugs = Array.isArray(parsed.cascade)
    ? parsed.cascade.flatMap((item) => {
        const proposal = parseProposalOutcome(item)
        return proposal ? [proposal.slug] : []
      })
    : []

  return { slug, state, cascadeSlugs }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseDeleteProposal(context)
  if (!result) return null
  return result.cascadeSlugs.length > 0
    ? `Withdrew ${result.slug} and ${result.cascadeSlugs.length} downstream proposal${result.cascadeSlugs.length === 1 ? "" : "s"}`
    : `Withdrew ${result.slug}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseDeleteProposal(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        <span className="font-mono text-gray-500 dark:text-gray-400">{result.slug}</span>
      </div>
      {result.cascadeSlugs.length > 0 ? (
        <div>
          <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">
            Also withdrawn ({result.cascadeSlugs.length})
          </div>
          <div className="mt-1 flex flex-wrap gap-1">
            {result.cascadeSlugs.map((slug) => <Badge key={slug}>{slug}</Badge>)}
          </div>
        </div>
      ) : null}
    </CardShell>
  )
}

const deleteProposalToolCard: ToolCardRenderer = {
  toolName: "delete_proposal",
  collapsedSummary,
  renderExpanded
}

export default deleteProposalToolCard
