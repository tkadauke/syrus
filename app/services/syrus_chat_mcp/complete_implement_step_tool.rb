require "mcp"

module SyrusChatMcp
  # Called by the Local Mode agent after the daemon has committed and pushed
  # the implementation. Releases the coding lock and kicks off graders.
  class CompleteImplementStepTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "complete_implement_step"

    description <<~DESC
      Signal that implementation is complete after the local daemon has
      committed and pushed changes to the branch. Releases the local coding
      lock and triggers Syrus graders (and PR open if needed). Call this only
      after `git_status` confirms a clean working tree and the branch has been
      pushed to the remote.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to hand off." },
        branch_name: {
          type: "string",
          description: "Branch name pushed to the remote. Required for new coding Jobs that do not yet have a PR; ignored for existing Jobs with a PR."
        }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, branch_name: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error

        unless job.coding?
          return SyrusChatMcp.invalid("Job #{job_id} is not in coding state (current: #{job.state}).")
        end
        unless job.linked_chat_id == chat_session.id
          return SyrusChatMcp.invalid("Job #{job_id} is not linked to this chat session.")
        end
        if job.pr_number.blank? && branch_name.blank?
          return SyrusChatMcp.invalid("branch_name is required for Jobs without an existing PR.")
        end

        ApplicationRecord.transaction do
          job.branch_name = branch_name if branch_name.present? && job.branch_name.blank?
          job.linked_chat_id = nil
          job.exit_local_mode!
          job.save!
        end

        workflow = Workflows::LocalModeHandoff.instantiate(job: job, agent_provider: job.agent_provider)
        StepDispatcher.start_workflow(workflow)

        SyrusChatMcp.success(
          job_id: job.id,
          job_state: job.reload.state,
          workflow_id: workflow.id,
          message: "Implementation handed off. Graders and PR workflow enqueued (workflow #{workflow.id})."
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
