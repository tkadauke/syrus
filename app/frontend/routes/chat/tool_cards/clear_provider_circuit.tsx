import { pendingActionToolCard } from "../pendingActionToolCard"

const clearProviderCircuitToolCard = pendingActionToolCard("clear_provider_circuit", {
  inputFields: [
    { key: "provider", format: "badge" },
    { key: "mode", format: "badge" },
    { key: "user_id", label: "User", format: "badge" },
    { key: "user_ids", label: "Users", format: "list" },
    { key: "retry_after" },
    { key: "positive_evidence", format: "markdown" },
    { key: "reason", format: "markdown" }
  ]
})

export default clearProviderCircuitToolCard
