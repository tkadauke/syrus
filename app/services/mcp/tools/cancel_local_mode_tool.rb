require "mcp"

module Mcp::Tools
  # Cancels the local mode coding session for the Job linked to this chat.
  # For taken-over Jobs (have a PR), returns them to implemented state.
  # For brand-new coding Jobs (no PR), closes them.
  class CancelLocalModeTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "cancel_local_mode"

    description <<~DESC
      Cancel the active local mode coding session for a Job linked to this
      chat. Jobs that had a PR before entering local mode return to
      `implemented`; brand-new Jobs created in local mode are closed. Any
      uncommitted daemon changes should be stashed or discarded before
      calling this tool.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to cancel local mode for." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error

        unless job.coding?
          return Mcp::Tools.invalid("Job #{job_id} is not in coding state (current: #{job.state}).")
        end
        unless job.linked_chat_id == chat_session.id
          return Mcp::Tools.invalid("Job #{job_id} is not linked to this chat session.")
        end

        new_state = ApplicationRecord.transaction do
          job.linked_chat_id = nil
          if job.pr_number.present?
            # Taken-over Job — return to implemented so it can be re-approved
            job.exit_local_mode!
            job.save!
            job.state
          else
            # New coding Job with no PR — close it
            job.save!
            job.cancel_active_runs_and_close!("local_mode_cancelled")
            job.state
          end
        end

        Mcp::Tools.success(
          job_id: job.id,
          job_state: new_state,
          message: "Local mode session cancelled. Job #{job_id} is now #{new_state}."
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
