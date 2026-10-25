require "mcp"

module Mcp::Tools
  class PollJobFeedbackTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "poll_job_feedback"

    description "Request polling PR feedback for a Syrus Job. Polling is not enqueued until the operator confirms the pending action."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to poll for PR feedback." },
        job_ids: { type: "array", items: { type: "integer" }, maxItems: BulkPendingActionToolSupport::MAX_BATCH_SIZE, description: "Multiple Job ids to poll as one grouped pending action." }
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
          action: "poll_job_feedback",
          payload: { "job_id" => job.id },
          message: "Poll PR feedback for #{job.slug}?"
          )
        end
        group = create_pending_action_group!(server_context:, chat_session:, member_attributes: jobs.map { |job|
          { action: "poll_job_feedback", payload: { "job_id" => job.id }, requested_by: "agent" }
        })
        bulk_action_response(group:, message: I18n.t("server.mcp.bulk_confirmation.poll_job_feedback", count: jobs.size))
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
