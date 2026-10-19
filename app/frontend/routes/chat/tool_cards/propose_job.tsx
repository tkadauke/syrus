import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseProposalOutcome, proposalOutcomeSummary, ProposalOutcomeCard } from "../proposalToolCard"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

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

  const proposal = parseProposalOutcome(context.parsedResult, context.input)
  if (!proposal) return null
  return proposalOutcomeSummary(proposal)
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const proposal = parseProposalOutcome(context.parsedResult, context.input)
  if (!proposal) return null
  return <ProposalOutcomeCard proposal={proposal} />
}

const proposeJobToolCard: ToolCardRenderer = {
  toolName: "propose_job",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "detailed_job_proposal",
    label: "Detailed Job proposal",
    description: "Markdown, linked dependencies, placement, media, and investigation metadata.",
    input: {
      epic_id: 42,
      media: ["chat_image:17", "snapshot:23"],
      provider: "codex",
      planned_execution: { project_label: "Web", capabilities: { os: ["linux"] } }
    },
    parsedResult: {
      slug: "job-improve-proposal-card",
      title: "Improve proposal card",
      body: "Render **all fields** and link JOB-12.",
      kind: "job",
      state: "proposed",
      labels: ["frontend", "chat"],
      repository: "tkadauke/syrus",
      dependencies: ["job-card-primitives"],
      depends_on_job_ids: [12],
      investigation: true,
      initial_job_state: "backlog",
      provider_setting: "codex",
      planned_execution: { project_label: "Web", capabilities: { os: ["linux"] } }
    }
  }
]

export default proposeJobToolCard
