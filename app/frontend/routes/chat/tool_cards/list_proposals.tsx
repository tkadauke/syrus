import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { EmptyState } from "../toolCardUi"
import { parseProposalOutcome, ProposalOutcomeCard, type ProposalOutcome } from "../proposalToolCard"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for list_proposals (the pending-action tool-card work).
function proposalRows(context: ToolCardContext): ProposalOutcome[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.proposals)) return null

  return parsed.proposals.flatMap((item) => {
    const proposal = parseProposalOutcome(item, context.input, context.presentation)
    return proposal ? [proposal] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary
  const rows = proposalRows(context)
  if (!rows) return null
  return `${rows.length} proposal${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const rows = proposalRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>No proposals in this chat yet.</EmptyState>

  return (
    <div className="mt-1 grid min-w-0 gap-2">
      {rows.map((proposal) => <ProposalOutcomeCard key={proposal.slug} onLinkClick={context.onLinkClick} proposal={proposal} />)}
    </div>
  )
}

const failureConfig: ToolFailureConfig = {
  title: "Proposal list",
  attempted: () => "List proposals",
  retrySafety: "safe",
  recovery: "Retry after checking the chat connection."
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
          title: "Fix output",
          body: "Render **linked** dependency details for JOB-12.",
          kind: "job",
          state: "proposed",
          repository: "tkadauke/syrus",
          dependencies: ["card-primitives"],
          depends_on_job_ids: [12],
          target_epic: { id: 7, label: "Chat polish" },
          materialized: { kind: "job", job_id: 91, job_title: "Fix output", job_state: "queued" }
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
