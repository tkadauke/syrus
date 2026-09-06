require "mcp"

module Mcp::Tools
  class ReopenJobTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "reopen_job"

    description <<~DESC
      Request reopening one or more closed Syrus Jobs. Pass job_id for a
      single Job (unchanged single-confirmation behavior) or job_ids for
      multiple Jobs, which creates one grouped pending action the operator
      confirms or rejects together. The Job(s) are not reopened until the
      operator confirms.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to reopen." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to reopen as one grouped pending action."
        }
      }
    )

    class << self
      def call(job_id: nil, job_ids: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error

        jobs = []
        ids.each do |id|
          job, error = user_job(chat_session, id)
          return error if error

          jobs << job
        end

        unless bulk
          job = jobs.first
          return create_pending_action!(
            server_context,
            chat_session,
            action: "reopen_job",
            payload: { "job_id" => job.id },
            message: "Reopen #{job.slug}?"
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: jobs.map { |job| { action: "reopen_job", payload: { "job_id" => job.id }, requested_by: "agent" } }
        )
        bulk_action_response(group: group, message: "Reopen #{jobs.size} Jobs?")
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
