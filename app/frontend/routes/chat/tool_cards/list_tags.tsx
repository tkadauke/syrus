import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { renderTagList, tagListSummary } from "../issueTagArtifactToolCard"

const listTagsToolCard: ToolCardRenderer = {
  toolName: "list_tags",
  collapsedSummary: (context: ToolCardContext) => tagListSummary(context),
  renderExpanded: (context: ToolCardContext) => renderTagList(context)
}

export default listTagsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "tags_with_jobs",
    label: "Tags with Jobs",
    parsedResult: {
      tags: [
        { id: 1, name: "area:ui", color: "blue", job_ids: [7, 8] },
        { id: 2, name: "urgent", color: "#991b1b", job_ids: [] }
      ]
    }
  },
  { id: "empty", label: "No tags", parsedResult: { tags: [] } },
  { id: "loading", label: "Loading" },
  { id: "error", label: "Error", resultBody: "Unable to list tags", resultError: true }
]
