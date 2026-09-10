import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { IssueListCard, issueListSummary, issueRows } from "../utilityToolCards"

function renderExpanded(context: ToolCardContext) {
  const rows = issueRows(context)
  if (!rows) return null
  return <IssueListCard rows={rows} />
}

const listOpenIssuesToolCard: ToolCardRenderer = {
  toolName: "list_open_issues",
  collapsedSummary: issueListSummary,
  renderExpanded
}

export default listOpenIssuesToolCard
