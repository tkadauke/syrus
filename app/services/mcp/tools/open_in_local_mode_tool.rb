require "mcp"

module Mcp::Tools
  # Lets the Local Mode chat agent take over an existing implemented/approved Job.
  # Unapproves if needed, links the Job to this chat, and transitions it to coding.
  class OpenInLocalModeTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "open_in_local_mode"

    description <<~DESC
      Take over an existing Syrus Job for direct implementation via the local
      daemon in this chat session. The Job must be in `implemented` or
      `approved` state; approved Jobs are automatically unapproved first.
      After this call succeeds, run `git_status` to see the current branch,
      then implement changes using the local tools. When done, call
      `complete_implement_step` to release the lock and trigger graders.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to open in local mode." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error

        if job.linked_chat_id.present?
          return Mcp::Tools.invalid("Job #{job_id} is already linked to a local coding session.")
        end
        unless job.implemented? || job.approved?
          return Mcp::Tools.invalid("Job #{job_id} must be in implemented or approved state (current: #{job.state}).")
        end

        ApplicationRecord.transaction do
          if job.approved?
            Job::ApprovalUnapprover.call(job: job, user: chat_session.user)
          end
          job.linked_chat_id = chat_session.id
          job.enter_local_mode!
          job.save!
        end

        Mcp::Tools.success(
          job_id: job.id,
          job_state: job.reload.state,
          branch_name: job.branch_name,
          repository_slug: job.repository.slug,
          message: "Job #{job_id} is now open for local implementation on branch `#{job.branch_name}`."
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
