import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const wakeProviderAdmissionToolCard = pendingActionToolCard("wake_provider_admission", {
  inputFields: [
    { key: "provider", format: "badge" },
    { key: "user_id", label: "User scope", format: "entity", hrefPrefix: "/admin/users", emptyLabel: "All users" },
    { key: "reason", format: "markdown" }
  ],
  resultFields: [
    { path: "observed_preview.workflow_count", label: "Queued workflows", format: "number" },
    { path: "observed_preview.auto_retry_count", label: "Delayed auto-retries", format: "number" }
  ]
})

export default wakeProviderAdmissionToolCard
