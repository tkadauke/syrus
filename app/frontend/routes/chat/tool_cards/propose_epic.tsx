import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseProposalOutcome, proposalOutcomeSummary, ProposalOutcomeCard } from "../proposalToolCard"

// Core-owned tool card for propose_epic (EPIC-292 / JOB-4222). Shares the
// propose_job parser/renderer since both tools return the same
// Mcp::Tools.proposal_payload shape.
function collapsedSummary(context: ToolCardContext) {
  const proposal = parseProposalOutcome(context.parsedResult)
  if (!proposal) return null
  return proposalOutcomeSummary(proposal)
}

function renderExpanded(context: ToolCardContext) {
  const proposal = parseProposalOutcome(context.parsedResult)
  if (!proposal) return null
  return <ProposalOutcomeCard proposal={proposal} />
}

const proposeEpicToolCard: ToolCardRenderer = {
  toolName: "propose_epic",
  collapsedSummary,
  renderExpanded
}

export default proposeEpicToolCard
