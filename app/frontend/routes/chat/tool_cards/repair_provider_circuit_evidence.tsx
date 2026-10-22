import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const repairProviderCircuitEvidenceToolCard = pendingActionToolCard("repair_provider_circuit_evidence", {
  inputFields: [
    { key: "evidence_type", format: "badge" },
    { key: "evidence_id", format: "entity", entityKind: "artifact" },
    { key: "evidence_ids", format: "entity_list", entityKind: "artifact" },
    { key: "repair_status", format: "badge" },
    { key: "reason", format: "markdown" }
  ],
  observedSummary: true
})

export default repairProviderCircuitEvidenceToolCard
