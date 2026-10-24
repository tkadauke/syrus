require "mcp"

module Mcp::Tools
  class ForceStateTransitionTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "force_state_transition"
    description <<~DESC
      Request one event from the enumerated allowlist for a Job in any state.
      Eligibility is exact per event: the Job's AASM may_<event>? guard must be
      true in its current state, both when requested and when confirmed. The call
      creates only a pending action; confirmation mutates the existing Job and
      creates no Job, Workflow, WorkUnit, admission-control request, or worker
      queue entry. Use the rejection's current state to choose a valid event.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        job_ids: { type: "array", items: { type: "integer" }, maxItems: BulkPendingActionToolSupport::MAX_BATCH_SIZE, description: "Multiple Job ids sharing one event and audit reason." },
        event: {
          type: "string",
          enum: JobStateRepair::ForceTransition::ALLOWED_EVENTS,
          description: "Allowed AASM event to apply to the Job."
        },
        reason: { type: "string", description: "Operator-facing audit reason for the transition." }
      },
      required: %w[event reason]
    )

    class << self
      def call(job_id: nil, job_ids: nil, event:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error
        jobs = ids.map { |id| Job.find_by(id: id) }
        missing = ids.zip(jobs).filter_map { |id, job| id unless job }
        return Mcp::Tools.invalid("job not found: #{missing.join(', ')}") if missing.any?
        invalid = jobs.reject { |job| JobStateRepair::ForceTransition::ALLOWED_EVENTS.include?(event.to_s) && job.public_send("may_#{event}?") }
        if invalid.any?
          details = invalid.map { |job| "#{job.slug} cannot apply #{event} from #{job.state}" }
          return Mcp::Tools.invalid(details.join(" | "))
        end

        unless bulk
          job = jobs.first
          return create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "force_state_transition",
          payload: { "job_id" => job.id, "event" => event.to_s },
          reason: reason,
          message: "Apply #{event} to #{job.slug}?"
          )
        end
        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?
        group = create_pending_action_group!(server_context:, chat_session:, reason:, member_attributes: jobs.map { |job|
          { action: "force_state_transition", payload: { "job_id" => job.id, "event" => event.to_s }, requested_by: "agent", reason: reason }
        })
        bulk_action_response(group:, message: "Apply #{event} to #{jobs.size} Jobs?")
      end
    end
  end
end
