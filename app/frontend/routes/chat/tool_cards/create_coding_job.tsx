import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { CreateCodingJobOutcomeCard, createCodingJobRequest, localModeJobOutcomeModel, localModeJobOutcomeSummary } from "../localModeJobOutcomeCard"

// Local Mode tool card for create_coding_job (the tool-card work). See
// open_in_local_mode.tsx for the shared family this belongs to.
function collapsedSummary(context: ToolCardContext) {
  const model = localModeJobOutcomeModel(context)
  if (model.error) return "Coding job creation failed"
  return model.result ? localModeJobOutcomeSummary(model.result) : createCodingJobRequest(context).title
}

function renderExpanded(context: ToolCardContext) {
  return <CreateCodingJobOutcomeCard context={context} />
}

export const examples: ToolCardExample[] = [
  {
    id: "created",
    label: "Coding job created",
    input: {
      title: "Improve repository search",
      body: `Add **ranked results** and preserve the selected filters.\n\n${"Include keyboard and mobile coverage. ".repeat(30)}`,
      repository_id: 12
    },
    parsedResult: {
      job_id: 7589,
      job_state: "queued",
      repository_slug: "tkadauke/syrus",
      message: "Created **JOB-7589** and queued it for implementation."
    }
  },
  {
    id: "error",
    label: "Coding job creation failed",
    input: { title: "Improve repository search", body: "Add **ranked results**.", repository_id: 12 },
    resultBody: "Repository is not available for coding jobs.",
    resultError: true
  }
]

const createCodingJobToolCard: ToolCardRenderer = {
  toolName: "create_coding_job",
  collapsedSummary,
  renderExpanded
}

export default createCodingJobToolCard
