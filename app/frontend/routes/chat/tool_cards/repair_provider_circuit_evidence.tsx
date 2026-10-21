import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const repairProviderCircuitEvidenceToolCard = pendingActionToolCard("repair_provider_circuit_evidence", {
  inputFields: [
    { key: "evidence_type", format: "badge" },
    { key: "evidence_id" },
    { key: "evidence_ids", format: "list" },
    { key: "repair_status", format: "badge" },
    { key: "reason", format: "markdown" }
  ]
})

export default repairProviderCircuitEvidenceToolCard
