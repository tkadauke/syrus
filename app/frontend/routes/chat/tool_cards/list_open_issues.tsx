import i18n from "@app/i18n"
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
    label: i18n.t("chat:tool_card_list_issues_example_results"),
    input: { state: "open", label: "bug", limit: 2 },
    parsedResult: {
      issues: [
        {
          number: 42,
          title: i18n.t("chat:tool_card_list_issues_example_title"),
          labels: ["bug", "frontend"],
          state: "open",
          author: "octocat",
          created_at: "2026-10-18T10:00:00Z",
          updated_at: "2026-10-20T08:00:00Z",
          url: "https://github.com/acme/widgets/issues/42",
          body_excerpt: `The navigation overlaps the main panel at narrow widths and makes the primary controls difficult to reach. ${"The content should reflow into a compact stacked presentation without hiding issue metadata. ".repeat(12)}\n\n![Screenshot](/icon-192.png)`
        }
      ]
    }
  },
  { id: "empty", label: i18n.t("chat:tool_card_list_issues_example_empty"), input: { state: "closed", limit: 20 }, parsedResult: { issues: [] } },
  { id: "error", label: i18n.t("chat:tool_card_provider_error"), input: { state: "open", limit: 20 }, resultError: true, resultBody: i18n.t("chat:tool_card_github_unavailable") }
]
