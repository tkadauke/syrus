require "mcp"

module Mcp::Tools
  class CloseJobSuccessfullyTool < MCP::Tool
    extend ProposalToolSupport
    extend BulkPendingActionToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "close_job_successfully"

    description <<~DESC
      Request that one or more Syrus Jobs be closed as a successful semantic
      outcome, such as no_changes. Pass job_id for a single Job (unchanged
      single-confirmation behavior) or job_ids for multiple Jobs, which
      creates one grouped pending action the operator confirms or rejects
      together -- every Job in the group is closed with the same
      closure_reason; use separate calls if different Jobs need different
      reasons. The Job(s) and any tracked PR are not changed until the
      operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to close successfully." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to close successfully as one grouped pending action, all with the same closure_reason."
        },
        closure_reason: {
          type: "string",
          enum: Job::SUCCESSFUL_CLOSURE_REASONS,
          description: "Successful closure reason to record on the Job(s)."
        },
        comment: {
          type: "string",
          description: "Optional explanatory comment to post on the PR before closing it."
        }
      },
      required: %w[closure_reason]
    )

    class << self
      def call(job_id: nil, job_ids: nil, closure_reason:, comment: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        return Mcp::Tools.invalid("closure_reason is required") if closure_reason.blank?
        unless Job::SUCCESSFUL_CLOSURE_REASONS.include?(closure_reason.to_s)
          return Mcp::Tools.invalid("closure_reason must be one of #{Job::SUCCESSFUL_CLOSURE_REASONS.join(', ')}")
        end

        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error

        jobs = ids.map { |id| find_job!(id) }
        jobs.each do |job|
          return Mcp::Tools.invalid("#{job.slug} is already closed.") if job.closed?
          return Mcp::Tools.invalid("#{job.slug} cannot be closed from #{job.state}.") unless job.may_close?
        end

        unless bulk
          job = jobs.first
          payload = { "job_id" => job.id, "closure_reason" => closure_reason.to_s }
          payload["comment"] = comment.to_s if comment.present?

          pending_action = create_pending_action_for_current_message!(
            server_context,
            chat_session,
            action: "close_job_successfully",
            payload: payload,
            requested_by: "agent"
          )

          return Mcp::Tools.success(
            pending_confirmation_id: pending_action.id,
            pending_action_id: pending_action.id,
            state: pending_action.state,
            job_id: job.id,
            closure_reason: closure_reason.to_s,
            message: "Successful Job close requires operator confirmation."
          )
        end

        member_attributes = jobs.map do |job|
          member_payload = { "job_id" => job.id, "closure_reason" => closure_reason.to_s }
          member_payload["comment"] = comment.to_s if comment.present?
          { action: "close_job_successfully", payload: member_payload, requested_by: "agent" }
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: member_attributes
        )
        bulk_action_response(group: group, message: "Close #{jobs.size} Jobs as #{closure_reason}?")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
