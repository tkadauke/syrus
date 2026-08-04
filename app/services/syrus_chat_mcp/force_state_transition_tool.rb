require "mcp"

module SyrusChatMcp
  class ForceStateTransitionTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "force_state_transition"
    description "Request one allowed Job AASM event. Requires operator confirmation."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        event: {
          type: "string",
          enum: JobStateRepair::ForceTransition::ALLOWED_EVENTS,
          description: "Allowed AASM event to apply to the Job."
        },
        reason: { type: "string", description: "Operator-facing audit reason for the transition." }
      },
      required: %w[job_id event reason]
    )

    class << self
      def call(job_id:, event:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return SyrusChatMcp.invalid("job not found: #{job_id}") unless job

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "force_state_transition",
          payload: { "job_id" => job.id, "event" => event.to_s },
          reason: reason,
          message: "Apply #{event} to #{job.slug}?"
        )
      end
    end
  end
end
