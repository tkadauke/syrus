module PendingActions
  class RepairProviderCircuitEvidence < Base
    action_key "repair_provider_circuit_evidence"

    def execute
      ProviderCircuitEvidenceRepair.call(
        evidence_type: payload.fetch("evidence_type"),
        evidence_id: payload.fetch("evidence_id"),
        repair_status: payload.fetch("repair_status"),
        reason: reason,
        user: user
      )
    end

    def validate_payload(errors)
      errors.add(:payload, "evidence_type is required") if payload["evidence_type"].blank?
      errors.add(:payload, "evidence_id is required") if payload["evidence_id"].blank?
      errors.add(:payload, "repair_status is required") if payload["repair_status"].blank?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "#{payload["evidence_type"]}: #{payload["evidence_id"]}, status: #{payload["repair_status"]}"
    end

    def repair_action? = true
  end
end
