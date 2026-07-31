require "mcp"

module SyrusChatMcp
  class CloseJobSuccessfullyTool < MCP::Tool
    extend ProposalToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "close_job_successfully"

    description <<~DESC
      Request that a Syrus Job be closed as a successful semantic outcome, such
      as no_changes. The Job and any tracked PR are not changed until the
      operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to close successfully." },
        closure_reason: {
          type: "string",
          enum: Job::SUCCESSFUL_CLOSURE_REASONS,
          description: "Successful closure reason to record on the Job."
        },
        comment: {
          type: "string",
          description: "Optional explanatory comment to post on the PR before closing it."
        }
      },
      required: %w[job_id closure_reason]
    )

    class << self
      def call(job_id:, closure_reason:, comment: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job_id = Integer(job_id, exception: false)
        return SyrusChatMcp.invalid("job_id is required") unless job_id
        return SyrusChatMcp.invalid("closure_reason is required") if closure_reason.blank?
        unless Job::SUCCESSFUL_CLOSURE_REASONS.include?(closure_reason.to_s)
          return SyrusChatMcp.invalid("closure_reason must be one of #{Job::SUCCESSFUL_CLOSURE_REASONS.join(', ')}")
        end

        job = find_job!(job_id)
        return SyrusChatMcp.invalid("#{job.slug} is already closed.") if job.closed?
        return SyrusChatMcp.invalid("#{job.slug} cannot be closed from #{job.state}.") unless job.may_close?

        payload = {
          "job_id" => job.id,
          "closure_reason" => closure_reason.to_s
        }
        payload["comment"] = comment.to_s if comment.present?

        pending_action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          action: "close_job_successfully",
          payload: payload,
          requested_by: "agent"
        )

        SyrusChatMcp.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          job_id: job.id,
          closure_reason: closure_reason.to_s,
          message: "Successful Job close requires operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
