import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { artifactSummary, renderArtifact } from "../issueTagArtifactToolCard"

const submitArtifactToolCard: ToolCardRenderer = {
  toolName: "submit_artifact",
  collapsedSummary: (context: ToolCardContext) => artifactSummary(context),
  renderExpanded: (context: ToolCardContext) => renderArtifact(context)
}

export default submitArtifactToolCard
