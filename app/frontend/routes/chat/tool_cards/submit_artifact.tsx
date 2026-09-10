import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { ArtifactSubmissionCard, artifactInfo, artifactSummary } from "../utilityToolCards"

function renderExpanded(context: ToolCardContext) {
  const artifact = artifactInfo(context)
  if (!artifact) return null
  return <ArtifactSubmissionCard artifact={artifact} />
}

const submitArtifactToolCard: ToolCardRenderer = {
  toolName: "submit_artifact",
  collapsedSummary: artifactSummary,
  renderExpanded
}

export default submitArtifactToolCard
