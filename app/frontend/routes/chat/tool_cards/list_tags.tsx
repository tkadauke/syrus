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
    label: "Tags with mapped Jobs",
    parsedResult: {
      tags: [
        { id: 1, name: "area:auth", color: "#123abc", job_ids: [7, 8] },
        { id: 2, name: "urgent", color: "red", job_ids: [8] },
        { id: 3, name: "ready", color: "green", job_ids: [] }
      ]
    }
  },
  {
    id: "empty",
    label: "No tags",
    parsedResult: { tags: [] }
  },
  {
    id: "error",
    label: "List error",
    resultBody: "Unable to load tags",
    resultError: true
  }
]
