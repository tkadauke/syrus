import { pendingActionToolCard } from "../pendingActionToolCard"

const repairProviderCircuitEvidenceToolCard = pendingActionToolCard("repair_provider_circuit_evidence", {
  inputFields: [
    { key: "evidence_type", format: "badge" },
    { key: "evidence_id", format: "badge" },
    { key: "evidence_ids", label: "Evidence ids", format: "list" },
    { key: "repair_status", format: "badge" },
    { key: "reason", format: "markdown" }
  ]
})

export default repairProviderCircuitEvidenceToolCard
