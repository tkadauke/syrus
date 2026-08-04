require "mcp"

module SyrusChatMcp
  class ForceFailJobTool < MCP::Tool
    extend ProposalToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "force_fail_job"

    description <<~DESC
      Request that an admin force a Syrus Job into failed state. The Job is not
      force-failed until the operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to force into failed state." },
        reason: { type: "string", description: "Operator-facing reason for force-failing this Job." }
      },
      required: %w[job_id reason]
    )

    class << self
      def call(job_id:, reason:, server_context:)
        return SyrusChatMcp.unauthorized("Admin access required") unless admin?

        chat_session = server_context.fetch(:chat_session)
        job_id = Integer(job_id, exception: false)
        return SyrusChatMcp.invalid("job_id is required") unless job_id
        reason = reason.to_s.strip
        return SyrusChatMcp.invalid("reason is required") if reason.empty?

        job = find_job!(job_id)
        return SyrusChatMcp.invalid("#{job.slug} is #{job.state} and cannot be force-failed.") unless job.may_force_fail?

        pending_action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          action: "force_fail_job",
          payload: { "job_id" => job.id, "previous_state" => job.state },
          reason: reason,
          requested_by: "agent"
        )

        SyrusChatMcp.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          job_id: job.id,
          previous_state: job.state,
          new_state: "failed",
          reason: pending_action.reason,
          message: "Force fail #{job.slug}?"
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
