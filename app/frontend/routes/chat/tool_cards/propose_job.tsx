import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseProposalOutcome, proposalOutcomeSummary, ProposalOutcomeCard } from "../proposalToolCard"

// Core-owned tool card for propose_job (EPIC-292 / JOB-4222).
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

const proposeJobToolCard: ToolCardRenderer = {
  toolName: "propose_job",
  collapsedSummary,
  renderExpanded
}

export default proposeJobToolCard
