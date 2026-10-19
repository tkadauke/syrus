import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseProposalOutcome, proposalOutcomeSummary, ProposalOutcomeCard } from "../proposalToolCard"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for propose_epic (the pending-action tool-card work). Shares the
// propose_job parser/renderer since both tools return the same
// Mcp::Tools.proposal_payload shape.
const failureConfig: ToolFailureConfig = {
  title: "Epic proposal",
  attempted: (context) => {
    const title = stringFromInput(context, ["title", "name"])
    return title ? `Propose Epic: ${title}` : "Propose an Epic"
  },
  retrySafety: "caution",
  recovery: "Use propose_epic_with_jobs to propose the Epic together with at least one child Job."
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const proposal = parseProposalOutcome(context.parsedResult, context.input, context.presentation)
  if (!proposal) return null
  return proposalOutcomeSummary(proposal)
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const proposal = parseProposalOutcome(context.parsedResult, context.input, context.presentation)
  if (!proposal) return null
  return <ProposalOutcomeCard onLinkClick={context.onLinkClick} proposal={proposal} />
}

export const examples: ToolCardExample[] = [
  {
    id: "deprecated_tool_failure",
    label: "Deprecated Epic proposal",
    description: "The deprecated tool directs the caller to propose the Epic with child Jobs.",
    input: { title: "Improve proposal cards", description: "Render **rich proposal details**." },
    resultBody: "Error: propose_epic no longer accepts zero-child Epic proposals. Call propose_epic_with_jobs instead.",
    resultError: true
  },
  {
    id: "materialized_epic",
    label: "Materialized Epic with child Jobs",
    parsedResult: {
      slug: "improve-proposal-cards",
      title: "Improve proposal cards",
      body: "Render **rich proposal details** and link every child Job.",
      kind: "epic",
      state: "confirmed",
      labels: ["frontend", "chat"],
      materialized: {
        kind: "epic",
        epic_id: 292,
        child_jobs: [
          { job_id: 4222, title: "Add core cards" },
          { job_id: 4223, title: "Add plugin cards" }
        ]
      }
    }
  }
]

const proposeEpicToolCard: ToolCardRenderer = {
  toolName: "propose_epic",
  collapsedSummary,
  renderExpanded
}

export default proposeEpicToolCard
