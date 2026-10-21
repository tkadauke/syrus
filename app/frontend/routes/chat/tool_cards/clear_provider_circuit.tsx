import type { ToolCardExample } from "@app/pluginToolCards"
import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const clearProviderCircuitToolCard = pendingActionToolCard("clear_provider_circuit", {
  inputFields: [
    { key: "provider", format: "badge" },
    { key: "mode", format: "badge" },
    { key: "user_id", label: "User", format: "entity", hrefPrefix: "/admin/users" },
    { key: "user_ids", label: "Users", format: "entity_list", hrefPrefix: "/admin/users" },
    { key: "retry_after" },
    { key: "positive_evidence", format: "markdown" },
    { key: "reason", format: "markdown" }
  ]
})

const LONG_POSITIVE_EVIDENCE = [
  "## Recovery evidence",
  "A successful provider probe completed after the last recorded quota response.",
  "The account can create a fresh session, stream output, and finish a representative request without retrying.",
  "The operator also checked the provider dashboard and confirmed that no active quota incident remains."
].join("\n\n")

export const examples: ToolCardExample[] = [
  {
    id: "long_markdown_evidence",
    label: "Long Markdown evidence",
    description: "Shows linked targets, badges, wrapping, Markdown previews, and the shared Show more dialog.",
    input: {
      provider: "codex",
      mode: "shorten",
      user_ids: [7, 12],
      retry_after: "2026-10-21T15:30:00Z",
      positive_evidence: LONG_POSITIVE_EVIDENCE,
      reason: "Restore access for **verified users** after reviewing [provider status](https://status.openai.com/)."
    },
    parsedResult: {
      pending_action_group_id: 91,
      pending_action_id: 507,
      pending_confirmation_id: 507,
      state: "pending",
      member_count: 2,
      message: "Shorten the circuit for user #7 and user #12? Contact operator@example.com if the recovery signal changes.",
      reason:
        "Recovery is supported by **new positive evidence** and should be reviewed before confirmation.\n\nThe full audit note remains available in this preview."
    }
  }
]

export default clearProviderCircuitToolCard
