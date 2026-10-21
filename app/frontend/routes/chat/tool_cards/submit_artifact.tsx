import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { artifactSummary, renderArtifact } from "../issueTagArtifactToolCard"

const submitArtifactToolCard: ToolCardRenderer = {
  toolName: "submit_artifact",
  renderWhilePending: true,
  collapsedSummary: (context: ToolCardContext) => artifactSummary(context),
  renderExpanded: (context: ToolCardContext) => renderArtifact(context)
}

export const examples: ToolCardExample[] = [
  {
    id: "chat_prose",
    label: "Chat prose artifact",
    input: { type: "report", title: "Review report", payload: { summary: "Found **two** issues. See JOB-42." } },
    parsedResult: { message: "Saved.", chat_session_id: 1 }
  },
  {
    id: "workflow_image",
    label: "Workflow screenshot artifact",
    input: { type: "screenshot", title: "Mobile view", payload: { screenshot_url: "/icon-192.png" } },
    parsedResult: { message: "Saved.", workflow_id: 28622, run_id: 230581, job_id: 7705 }
  },
  { id: "pending", label: "Pending submission", input: { type: "report", title: "Review report", payload: {} }, resultSettled: false },
  {
    id: "error",
    label: "Submission error",
    input: { type: "report", title: "Review report", payload: {} },
    resultBody: "Storage unavailable",
    resultError: true
  }
]

export default submitArtifactToolCard
