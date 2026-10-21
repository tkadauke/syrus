require "mcp"

module Mcp::Tools
  class OverrideJobPlannedExecutionTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "override_job_planned_execution"
    description "Inspect or request an audited placement override for a not-yet-started Job. Live changes require operator confirmation."
    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        profile: { type: "string", enum: ExecutionPlacementProfile::PROFILES.keys, description: "Complete validated replacement profile." },
        reason: { type: "string", description: "Operator-facing audit reason." },
        dry_run: { type: "boolean", description: "Return the exact repair plan without mutation." }
      },
      required: %w[job_id profile reason]
    )

    class << self
      def call(job_id:, profile:, reason:, server_context:, dry_run: false)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: Integer(job_id, exception: false))
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        inspection = operation(job, profile, chat_session.user, reason).inspect
        return Mcp::Tools.success(inspection.as_json.merge(dry_run: true)) if dry_run
        return Mcp::Tools.invalid(inspection.reason) unless inspection.eligible

        create_pending_admin_action(
          server_context:, chat_session:, action: "override_job_planned_execution",
          payload: { "job_id" => job.id, "profile" => inspection.profile.name, "observed_entity_revision" => job.entity_revision },
          reason:, message: "Change #{job.slug} placement from #{inspection.before.dig('capabilities', 'os')&.join('/')} to #{inspection.profile.label}?",
          extra: inspection.as_json
        )
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
