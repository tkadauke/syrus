import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { issueListSummary, renderIssueList } from "../issueTagArtifactToolCard"

const listOpenIssuesToolCard: ToolCardRenderer = {
  toolName: "list_open_issues",
  collapsedSummary: (context: ToolCardContext) => issueListSummary(context),
  renderExpanded: (context: ToolCardContext) => renderIssueList(context)
}

export default listOpenIssuesToolCard

export const examples: ToolCardExample[] = [
  {
    id: "issues_with_details",
    label: "Issues with details",
    input: { state: "open", label: "bug", limit: 2 },
    parsedResult: {
      issues: [
        {
          number: 42,
          title: "Responsive navigation overlaps content on smaller screens",
          labels: ["bug", "frontend"],
          state: "open",
          author: "octocat",
          created_at: "2026-10-18T10:00:00Z",
          updated_at: "2026-10-20T08:00:00Z",
          url: "https://github.com/acme/widgets/issues/42",
          body_excerpt: "The navigation overlaps the main panel.\n\n![Screenshot](https://example.test/overlap.png)"
        }
      ]
    }
  },
  { id: "empty", label: "No matching issues", input: { state: "closed", limit: 20 }, parsedResult: { issues: [] } },
  { id: "error", label: "Provider error", input: { state: "open", limit: 20 }, resultError: true, resultBody: "GitHub is unavailable." }
]
