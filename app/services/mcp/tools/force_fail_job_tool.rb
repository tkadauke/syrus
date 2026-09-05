require "mcp"

module Mcp::Tools
  class ForceFailJobTool < MCP::Tool
    extend ProposalToolSupport
    extend BulkPendingActionToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "force_fail_job"

    description <<~DESC
      Request that an admin force one or more Syrus Jobs into failed state.
      Pass job_id for a single Job (unchanged single-confirmation behavior)
      or job_ids for multiple Jobs, which requires a shared reason (the root
      cause behind force-failing every Job in the batch) and creates one
      grouped pending action the operator confirms or rejects together. No
      Job is force-failed until the operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to force into failed state." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to force-fail as one grouped pending action, sharing one reason."
        },
        reason: { type: "string", description: "Operator-facing reason for force-failing the Job(s)." }
      },
      required: %w[reason]
    )

    class << self
      def call(job_id: nil, job_ids: nil, reason:, server_context:)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?

        chat_session = server_context.fetch(:chat_session)
        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error

        jobs = ids.map { |id| find_job!(id) }
        jobs.each do |job|
          return Mcp::Tools.invalid("#{job.slug} is #{job.state} and cannot be force-failed.") unless job.may_force_fail?
        end

        unless bulk
          job = jobs.first
          pending_action = create_pending_action_for_current_message!(
            server_context,
            chat_session,
            action: "force_fail_job",
            payload: { "job_id" => job.id, "previous_state" => job.state },
            reason: reason,
            requested_by: "agent"
          )

          return Mcp::Tools.success(
            pending_confirmation_id: pending_action.id,
            pending_action_id: pending_action.id,
            state: pending_action.state,
            job_id: job.id,
            previous_state: job.state,
            new_state: "failed",
            reason: pending_action.reason,
            message: "Force fail #{job.slug}?"
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: jobs.map { |job|
            { action: "force_fail_job", payload: { "job_id" => job.id, "previous_state" => job.state }, requested_by: "agent", reason: reason }
          },
          reason: reason
        )
        bulk_action_response(group: group, message: "Force fail #{jobs.size} Jobs?")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
