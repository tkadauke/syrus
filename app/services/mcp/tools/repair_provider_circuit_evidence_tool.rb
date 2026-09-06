require "mcp"

module Mcp::Tools
  class RepairProviderCircuitEvidenceTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "repair_provider_circuit_evidence"
    description <<~DESC
      Request an audited repair marking one or more provider-circuit
      evidence items false_positive, inconclusive, or transient. Preserves
      original diagnostics. Pass evidence_id for a single item (unchanged
      single-confirmation behavior) or evidence_ids for multiple items of
      the same evidence_type sharing one repair_status/reason (the root
      cause behind repairing every item in the batch), which creates one
      grouped pending action the operator confirms or rejects together.
      Requires operator confirmation.
    DESC

    input_schema(
      properties: {
        evidence_type: { type: "string", enum: ProviderCircuitEvidenceRepair::EVIDENCE_TYPES, description: "provider_availability_evidence or run_failure_classification." },
        evidence_id: { type: "integer", description: "Evidence record id." },
        evidence_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple evidence record ids of the same evidence_type to repair as one grouped pending action, sharing one repair_status/reason."
        },
        repair_status: { type: "string", enum: ProviderCircuitEvidenceRepair::REPAIR_STATUSES, description: "Operator classification for this evidence item." },
        reason: { type: "string", description: "Operator-facing audit reason." }
      },
      required: %w[evidence_type repair_status reason]
    )

    class << self
      def call(evidence_type:, repair_status:, reason:, evidence_id: nil, evidence_ids: nil, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        ids, bulk, error = resolve_ids(id: evidence_id, ids: evidence_ids, param_name: "evidence_id")
        return error if error

        records = ids.map { |id| find_record(evidence_type, id) }
        missing = ids.zip(records).select { |_id, record| record.nil? }.map(&:first)
        return Mcp::Tools.invalid("evidence not found: #{evidence_type} #{missing.join(', ')}") if missing.any?
        blocked = records.select { |record| structured_quota_evidence?(record) }
        return Mcp::Tools.invalid("structured quota evidence cannot be repaired through this tool: #{blocked.map(&:id).join(', ')}") if blocked.any?

        payload_for = lambda do |id, record|
          {
            "evidence_type" => evidence_type.to_s,
            "evidence_id" => id,
            "repair_status" => repair_status.to_s,
            "observed" => observed_payload(record)
          }
        end

        unless bulk
          return create_pending_admin_action(
            server_context: server_context,
            chat_session: chat_session,
            action: "repair_provider_circuit_evidence",
            payload: payload_for.call(ids.first, records.first),
            reason: reason,
            message: "Mark #{evidence_type} ##{ids.first} as #{repair_status} for provider-circuit decisions?"
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: ids.zip(records).map { |id, record|
            { action: "repair_provider_circuit_evidence", payload: payload_for.call(id, record), requested_by: "agent", reason: reason }
          },
          reason: reason
        )
        bulk_action_response(group: group, message: "Mark #{records.size} #{evidence_type} evidence items as #{repair_status} for provider-circuit decisions?")
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
