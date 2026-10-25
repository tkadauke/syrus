require "mcp"

module Mcp::Tools
  class CheckJobMergeabilityTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "check_job_mergeability"

    description "Request a GitHub mergeability check for a Syrus Job. The check is not enqueued until the operator confirms the pending action."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to check mergeability for." },
        job_ids: { type: "array", items: { type: "integer" }, maxItems: BulkPendingActionToolSupport::MAX_BATCH_SIZE, description: "Multiple Job ids to check as one grouped pending action." }
      }
    )

    class << self
      def call(job_id: nil, job_ids: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error
        jobs = ids.map do |id|
          job, job_error = user_job(chat_session, id)
          return job_error if job_error
          job
        end

        unless bulk
          job = jobs.first
          return create_pending_action!(
          server_context,
          chat_session,
          action: "check_job_mergeability",
          payload: { "job_id" => job.id },
          message: "Check mergeability for #{job.slug}?"
          )
        end
        group = create_pending_action_group!(server_context:, chat_session:, member_attributes: jobs.map { |job|
          { action: "check_job_mergeability", payload: { "job_id" => job.id }, requested_by: "agent" }
        })
        bulk_action_response(group:, message: I18n.t("server.mcp.bulk_confirmation.check_mergeability", count: jobs.size))
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
