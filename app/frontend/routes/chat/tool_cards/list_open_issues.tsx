import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { issueListSummary, renderIssueList } from "../issueTagArtifactToolCard"

const listOpenIssuesToolCard: ToolCardRenderer = {
  toolName: "list_open_issues",
  collapsedSummary: (context: ToolCardContext) => issueListSummary(context),
  renderExpanded: (context: ToolCardContext) => renderIssueList(context)
}

export default listOpenIssuesToolCard
