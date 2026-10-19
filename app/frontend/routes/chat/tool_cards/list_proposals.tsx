import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { EmptyState } from "../toolCardUi"
import { parseProposalOutcome, ProposalOutcomeCard, type ProposalOutcome } from "../proposalToolCard"

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
  if (context.resultError) return "Proposal list failed"
  const rows = proposalRows(context)
  if (!rows && !context.resultBody && context.parsedResult == null) return "Loading proposals"
  if (!rows) return null
  return `${rows.length} proposal${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) {
    return <EmptyState>{context.resultBody.trim() || "Could not load proposals."}</EmptyState>
  }

  const rows = proposalRows(context)
  if (!rows && !context.resultBody && context.parsedResult == null) return <EmptyState>Loading proposals…</EmptyState>
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>No proposals in this chat yet.</EmptyState>

  return (
    <div className="mt-1 grid min-w-0 max-w-full gap-2 sm:grid-cols-2" data-testid="proposal-list">
      {rows.map((proposal) => (
        <div className="min-w-0 max-w-full" key={proposal.slug}>
          <ProposalOutcomeCard onLinkClick={context.onLinkClick} proposal={proposal} />
        </div>
      ))}
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
    label: "Mixed proposal states",
    parsedResult: {
      proposals: [
        {
          slug: "fix-output",
          title: "Fix output wrapping",
          body: "Render **markdown** and link https://example.test/design.",
          kind: "job",
          state: "confirmed",
          repository: "acme/widgets",
          dependencies: ["shared-markdown"],
          depends_on_job_ids: [42],
          target_epic: { id: 7, label: "Responsive chat" },
          materialized: { kind: "job", job_id: 99, job_title: "Fix output wrapping", job_state: "queued" }
        },
        { slug: "tier-2-cards", title: "Tier 2 Custom Tool Cards", body: "", kind: "epic", state: "withdrawn" }
      ]
    }
  },
  {
    id: "no_proposals",
    label: "No proposals",
    description: "Empty result set -- the card renders EmptyState instead of a bare table header.",
    parsedResult: { proposals: [] }
  }
]
