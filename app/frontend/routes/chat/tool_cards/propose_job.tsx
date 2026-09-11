import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseProposalOutcome, proposalOutcomeSummary, ProposalOutcomeCard } from "../proposalToolCard"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for propose_job (the pending-action tool-card work).
const failureConfig: ToolFailureConfig = {
  title: "Job proposal",
  attempted: (context) => {
    const title = stringFromInput(context, ["title", "prompt"])
    return title ? `Propose Job: ${title}` : "Propose a Job"
  },
  retrySafety: "caution",
  recovery: "Check whether a proposal card was created before retrying."
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const proposal = parseProposalOutcome(context.parsedResult)
  if (!proposal) return null
  return proposalOutcomeSummary(proposal)
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ToolFailureSummaryCard config={failureConfig} context={context} />

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
