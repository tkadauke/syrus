require "mcp"

module Mcp::Tools
  class RebaseJobTool < MCP::Tool
    extend ProposalToolSupport
    extend BulkPendingActionToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "rebase_job"

    description <<~DESC
      Request a rebase workflow for a Syrus Job in this repository. The rebase
      workflow is not enqueued until the operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to rebase." },
        job_ids: { type: "array", items: { type: "integer" }, maxItems: BulkPendingActionToolSupport::MAX_BATCH_SIZE, description: "Multiple Job ids to rebase normally as one grouped pending action." },
        reason: { type: "string", description: "Operator-facing reason for rebasing this Job." }
      },
      required: %w[reason]
    )

    class << self
      def call(job_id: nil, job_ids: nil, reason:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error
        jobs = ids.map { |id| find_job!(id) }
        ineligible = jobs.filter_map do |job|
          if !job.pr_number.present? && !job.external_pr_number.present?
            "#{job.slug}: no PR"
          elsif RebaseWorkflowSelector.active_for_stack?(job)
            "#{job.slug}: a rebase is already in progress"
          elsif RebaseWorkflowSelector.active_merge_train_for_stack?(job)
            "#{job.slug}: a merge train is already active"
          end
        end
        return Mcp::Tools.invalid(ineligible.join(" | ")) if ineligible.any?

        unless bulk
          job = jobs.first
          pending_action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          action: "rebase_job",
          payload: { "job_id" => job.id },
          reason: reason,
          requested_by: "agent"
        )

          return Mcp::Tools.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          reason: pending_action.reason,
          message: "Job rebase requires operator confirmation."
          )
        end

        group = create_pending_action_group!(server_context:, chat_session:, reason:, member_attributes: jobs.map { |job|
          { action: "rebase_job", payload: { "job_id" => job.id }, reason: reason, requested_by: "agent" }
        })
        bulk_action_response(group:, message: "Rebase #{jobs.size} Jobs normally?", extra: { reason: reason })
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
