require "mcp"

module Mcp::Tools
  class ApproveJobTool < MCP::Tool
    extend JobLifecycleToolSupport
    extend BulkPendingActionToolSupport

    tool_name "approve_job"

    description <<~DESC
      Approve one or more implemented Syrus Jobs in this chat session's
      repository. Pass job_id for a single Job, which approves it
      immediately (unchanged behavior), or job_ids for multiple Jobs, which
      creates one grouped pending action the operator confirms or rejects
      together before any Job is approved.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to approve." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to approve as one grouped pending action."
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
          job, error = find_repository_job(chat_session, id)
          return error if error

          jobs << job
        end

        unless bulk
          job = jobs.first
          return Mcp::Tools.invalid("job must be in implemented state") unless job.implemented?

          previous_state = job.state
          job.approve!(via: "operator", by_user: chat_session.user)

          return Mcp::Tools.success(job_id: job.id, previous_state: previous_state, new_state: job.reload.state)
        end

        not_implemented = jobs.reject(&:implemented?)
        if not_implemented.any?
          return Mcp::Tools.invalid("job must be in implemented state: #{not_implemented.map(&:slug).join(', ')}")
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: jobs.map { |job| { action: "approve_job", payload: { "job_id" => job.id }, requested_by: "agent" } }
        )
        bulk_action_response(group: group, message: "Approve #{jobs.size} Jobs?")
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
