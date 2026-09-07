import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { EmptyState, StatePill } from "../toolCardUi"
import { parseProposalOutcome, type ProposalOutcome } from "../proposalToolCard"

// Core-owned tool card for list_proposals (EPIC-292 / JOB-4222).
function proposalRows(context: ToolCardContext): ProposalOutcome[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.proposals)) return null

  return parsed.proposals.flatMap((item) => {
    const proposal = parseProposalOutcome(item)
    return proposal ? [proposal] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = proposalRows(context)
  if (!rows) return null
  return `${rows.length} proposal${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const rows = proposalRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>No proposals in this chat yet.</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Slug</th>
            <th className="px-2 py-1 font-semibold" scope="col">Kind</th>
            <th className="px-2 py-1 font-semibold" scope="col">State</th>
            <th className="px-2 py-1 font-semibold" scope="col">Title</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((proposal) => (
            <tr key={proposal.slug}>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-800 dark:text-gray-200">{proposal.slug}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{proposal.kind}</td>
              <td className="whitespace-nowrap px-2 py-1"><StatePill state={proposal.state} /></td>
              <td className="max-w-[20rem] truncate px-2 py-1 text-gray-600 dark:text-gray-300" title={proposal.title ?? undefined}>{proposal.title || "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const listProposalsToolCard: ToolCardRenderer = {
  toolName: "list_proposals",
  collapsedSummary,
  renderExpanded
}

export default listProposalsToolCard
