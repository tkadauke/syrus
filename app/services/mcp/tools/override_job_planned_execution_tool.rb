require "mcp"

module Mcp::Tools
  class OverrideJobPlannedExecutionTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "override_job_planned_execution"
    description "Inspect or request an audited placement override for a not-yet-started Job. Live changes require operator confirmation."
    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        job_ids: { type: "array", items: { type: "integer" }, maxItems: BulkPendingActionToolSupport::MAX_BATCH_SIZE, description: "Multiple Jobs sharing one replacement profile and audit reason." },
        profile: { type: "string", enum: ExecutionPlacementProfile::PROFILES.keys, description: "Complete validated replacement profile." },
        reason: { type: "string", description: "Operator-facing audit reason." },
        dry_run: { type: "boolean", description: "Return the exact repair plan without mutation." }
      },
      required: %w[profile reason]
    )

    class << self
      def call(job_id: nil, job_ids: nil, profile:, reason:, server_context:, dry_run: false)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)
        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error
        jobs = ids.map { |id| Job.find_by(id: id) }
        missing = ids.zip(jobs).filter_map { |id, job| id unless job }
        return Mcp::Tools.invalid("job not found: #{missing.join(', ')}") if missing.any?

        inspections = jobs.map { |job| operation(job, profile, chat_session.user, reason).inspect }
        return Mcp::Tools.success(results: inspections.map(&:as_json), dry_run: true) if dry_run && bulk
        return Mcp::Tools.success(inspections.first.as_json.merge(dry_run: true)) if dry_run
        ineligible = jobs.zip(inspections).filter_map { |job, inspection| "#{job.slug}: #{inspection.reason}" unless inspection.eligible }
        return Mcp::Tools.invalid(ineligible.join(" | ")) if ineligible.any?

        unless bulk
          job = jobs.first
          inspection = inspections.first
          return create_pending_admin_action(
          server_context:, chat_session:, action: "override_job_planned_execution",
          payload: { "job_id" => job.id, "profile" => inspection.profile.name, "observed_entity_revision" => job.entity_revision },
          reason:, message: "Change #{job.slug} placement from #{inspection.before.dig('capabilities', 'os')&.join('/')} to #{inspection.profile.label}?",
          extra: inspection.as_json
          )
        end
        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?
        group = create_pending_action_group!(server_context:, chat_session:, reason:, member_attributes: jobs.zip(inspections).map { |job, inspection|
          { action: "override_job_planned_execution", payload: { "job_id" => job.id, "profile" => inspection.profile.name, "observed_entity_revision" => job.entity_revision }, requested_by: "agent", reason: reason }
        })
        bulk_action_response(group:, message: I18n.t("server.mcp.bulk_confirmation.override_planned_execution", count: jobs.size))
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def operation(job, profile, actor, reason)
        PlannedExecutionOverrides::Operation.new(job:, profile:, actor:, reason:, provenance: "syrus_chat")
      end
    end
  end
end
