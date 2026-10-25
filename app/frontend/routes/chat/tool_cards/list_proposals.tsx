import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { EmptyState, EntityReference, StatePill } from "../toolCardUi"
import { parseProposalOutcome, type ProposalOutcome } from "../proposalToolCard"

// Core-owned tool card for list_proposals (the pending-action tool-card work).
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
  return i18n.t("chat:tool_card_list_proposals_summary", { count: rows.length })
}

function renderExpanded(context: ToolCardContext) {
  const rows = proposalRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>{i18n.t("chat:tool_card_list_proposals_empty")}</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            {["slug", "kind", "state", "title"].map((column) => (
              <th className="px-2 py-1 font-semibold" key={column} scope="col">{i18n.t(`chat:tool_card_list_proposals_${column}`)}</th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((proposal) => (
            <tr key={proposal.slug}>
              <td className="whitespace-nowrap px-2 py-1"><EntityReference kind="proposal" slug={proposal.slug} /></td>
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

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "mixed_proposals",
    label: i18n.t("chat:tool_card_list_proposals_example_mixed"),
    parsedResult: {
      proposals: [
        { slug: "fix-output", title: i18n.t("chat:tool_card_list_proposals_example_job"), kind: "job", state: "proposed" },
        { slug: "tier-2-cards", title: i18n.t("chat:tool_card_list_proposals_example_epic"), kind: "epic", state: "withdrawn" }
      ]
    }
  },
  {
    id: "no_proposals",
    label: i18n.t("chat:tool_card_list_proposals_example_empty"),
    description: i18n.t("chat:tool_card_list_proposals_example_empty_description"),
    parsedResult: { proposals: [] }
  }
]
