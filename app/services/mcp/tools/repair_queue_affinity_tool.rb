require "mcp"

module Mcp::Tools
  class RepairQueueAffinityTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    MAX_TARGETS = 100

    tool_name "repair_queue_affinity"
    description "Detect or select up to 100 queued Runs on unavailable worker/storage queues and repair them through one grouped operator confirmation."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        run_id: { type: "integer", description: "Queued Run id under this Job." },
        run_ids: { type: "array", items: { type: "integer" }, maxItems: MAX_TARGETS, description: "Queued Run ids to repair as one reviewed batch." },
        detector_scope: { type: "boolean", description: "Use the current dead-worker-queue detector result (up to 100 Runs)." },
        reason: { type: "string", description: "Operator-facing audit reason for repairing queue affinity." }
      },
      required: %w[reason]
    )

    class << self
      def call(reason:, server_context:, job_id: nil, run_id: nil, run_ids: nil, detector_scope: false)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        selected_ids = (Array(run_ids).presence || Array(run_id).presence)&.map(&:to_i)&.uniq
        detected = detector_scope ? DeadWorkerQueueDetector.call : DeadWorkerQueueDetector.call(run_ids: selected_ids)
        selected_ids = detected.map(&:run_id) if detector_scope
        return Mcp::Tools.invalid("provide run_id, run_ids, or detector_scope") if selected_ids.blank?
        return Mcp::Tools.invalid("at most #{MAX_TARGETS} Runs may be repaired together") if selected_ids.size > MAX_TARGETS

        runs = Run.where(id: selected_ids).includes(:job).index_by(&:id)
        missing = selected_ids.map(&:to_i).uniq - runs.keys
        return Mcp::Tools.invalid("runs not found: #{missing.join(', ')}") if missing.any?
        if job_id.present? && runs.values.any? { |candidate| candidate.job_id != job_id.to_i }
          return Mcp::Tools.invalid("one or more Runs do not belong to job #{job_id}")
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          reason: reason,
          member_attributes: selected_ids.map do |id|
            candidate = runs.fetch(id.to_i)
            {
              action: "repair_queue_affinity",
              requested_by: "agent",
              reason: reason,
              payload: {
                "job_id" => candidate.job_id,
                "workflow_id" => candidate.workflow_id,
                "run_id" => candidate.id,
                "queue_name" => detected.find { |item| item.run_id == candidate.id }&.queue_name
              }.compact
            }
          end
        )
        bulk_action_response(group: group, message: "Repair #{selected_ids.size} dead-queue Runs as one batch?", extra: {
          run_ids: selected_ids,
          workflow_ids: runs.values.map(&:workflow_id).compact.uniq,
          dead_queues: detected.map(&:queue_name).uniq.sort
        })
      end
    end
  end
end
