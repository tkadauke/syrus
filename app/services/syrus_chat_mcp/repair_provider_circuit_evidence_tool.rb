require "mcp"

module SyrusChatMcp
  class RepairProviderCircuitEvidenceTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "repair_provider_circuit_evidence"
    description "Request an audited repair marking a provider-circuit evidence item false_positive, inconclusive, or transient. Preserves original diagnostics and requires operator confirmation."

    input_schema(
      properties: {
        evidence_type: { type: "string", enum: ProviderCircuitEvidenceRepair::EVIDENCE_TYPES, description: "provider_availability_evidence or run_failure_classification." },
        evidence_id: { type: "integer", description: "Evidence record id." },
        repair_status: { type: "string", enum: ProviderCircuitEvidenceRepair::REPAIR_STATUSES, description: "Operator classification for this evidence item." },
        reason: { type: "string", description: "Operator-facing audit reason." }
      },
      required: %w[evidence_type evidence_id repair_status reason]
    )

    class << self
      def call(evidence_type:, evidence_id:, repair_status:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        evidence_id = integer_param(evidence_id, "evidence_id")
        return evidence_id if evidence_id.is_a?(MCP::Tool::Response)
        record = find_record(evidence_type, evidence_id)
        return SyrusChatMcp.invalid("evidence not found: #{evidence_type} #{evidence_id}") unless record
        return SyrusChatMcp.invalid("structured quota evidence cannot be repaired through this tool") if structured_quota_evidence?(record)

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "repair_provider_circuit_evidence",
          payload: {
            "evidence_type" => evidence_type.to_s,
            "evidence_id" => evidence_id,
            "repair_status" => repair_status.to_s,
            "observed" => observed_payload(record)
          },
          reason: reason,
          message: "Mark #{evidence_type} ##{evidence_id} as #{repair_status} for provider-circuit decisions?"
        )
      end

      private

      def find_record(evidence_type, evidence_id)
        case evidence_type.to_s
        when "provider_availability_evidence"
          ProviderAvailabilityEvidence.find_by(id: evidence_id)
        when "run_failure_classification"
          RunFailureClassification.find_by(id: evidence_id)
        end
      end

      def structured_quota_evidence?(record)
        record.is_a?(ProviderAvailabilityEvidence) &&
          record.source == "usage_probe" &&
          record.status.in?(%w[exhausted warning]) &&
          record.details.to_h["snapshot"].present?
      end

      def observed_payload(record)
        if record.respond_to?(:summary)
          return record.summary
        end

        {
          run_id: record.run_id,
          classification: record.classification,
          reason: record.reason,
          classified_at: record.classified_at&.iso8601,
          repair: record.repair_summary
        }.compact
      end
    end
  end
end
